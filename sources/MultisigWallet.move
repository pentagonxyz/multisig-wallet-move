module Multiture::MultisigWallet {
    use Std::Signer;
    use Std::Vector;

    use AptosFramework::Coin::{Self, Coin};
    use AptosFramework::IterableTable::{Self, IterableTable};
    use AptosFramework::Table::{Self, Table};
    use AptosFramework::Token::{Self, Token, TokenId};

    struct MultisigBank has key {
        multisigs: vector<Multisig>
    }

    struct Multisig has store {
        participants: IterableTable<address, bool>,
        approval_threshold: u64,
        cancellation_threshold: u64,
        proposals: vector<Proposal>,
        tokens: IterableTable<TokenId, Token>
    }

    struct Proposal has store {
        creator: address,
        posted: bool,
        votes: Table<address, bool>,
        approval_votes: u64,
        cancellation_votes: u64,
        approve_messages: vector<vector<u8>>,
        add_participants: vector<address>,
        remove_participants: vector<address>,
        withdraw_tokens: vector<PendingTokenWithdrawal>
    }

    struct PendingTokenWithdrawal has store, drop {
        tokenId: TokenId,
        value: u64,
        recipient: address
    }

    struct AuthToken has copy, drop, store {
        multisig_id: u64,
        proposal_id: u64
    }

    struct ObjectDepositRecord<T> has key {
        record: Table<u64, IterableTable<u64, T>>,
        next_id: u64
    }

    struct DepositRecord<phantom AssetType> has key {
        record: Table<u64, Coin<AssetType>>
    }

    struct PendingAuthedObjectWithdrawalRecord<phantom T> has key {
        record: Table<ProposalID, vector<u64>>
    }

    struct PendingAuthedWithdrawalRecord<phantom AssetType> has key {
        record: Table<ProposalID, u64>
    }

    struct PendingWithdrawalTransferRecord<phantom AssetType> has key {
        record: Table<ProposalID, PendingWithdrawalTransfer>
    }

    struct ProposalID has copy, drop, store {
        multisig_id: u64,
        proposal_id: u64
    }

    struct PendingWithdrawalTransfer has drop, store {
        recipient: address,
        amount: u64
    }

    public fun initialize(root: &signer) {
        assert!(Signer::address_of(root) == @Multiture, 1000); // INVALID_ROOT_SIGNER
        assert(!exists<MultisigBank>(@Multiture), 1000); // ALREADY_INITIALIZED
        move_to(root, MultisigBank { multisigs: Vector::empty<Multisig>() });
    }

    public fun enable_deposits<AssetType>(root: &signer) {
        // validate deposits are not yet enabled
        assert!(Signer::address_of(root) == @Multiture, 1000); // INVALID_ROOT_SIGNER
        assert!(!exists<DepositRecord<AssetType>>(@Multiture), 1000); // DEPOSITS_ALREADY_ENABLED

        // add deposit record and withdrawal request record
        move_to(root, DepositRecord<AssetType> { record: Table::new() });
        move_to(root, PendingAuthedWithdrawalRecord<AssetType> { record: Table::new() });
        move_to(root, PendingWithdrawalTransferRecord<AssetType> { record: Table::new() });
    }

    public fun enable_object_deposits<T: store>(root: &signer) {
        // validate deposits are not yet enabled
        assert!(Signer::address_of(root) == @Multiture, 1000); // INVALID_ROOT_SIGNER
        assert!(!exists<ObjectDepositRecord<T>>(@Multiture), 1000); // DEPOSITS_ALREADY_ENABLED

        // add deposit record and withdrawal request record
        move_to(root, ObjectDepositRecord<T> { record: Table::new(), next_id: 0 });
        move_to(root, PendingAuthedObjectWithdrawalRecord<T> { record: Table::new() });
    }

    public fun create_multisig(participants: vector<address>, approval_threshold: u64, cancellation_threshold: u64): u64 acquires MultisigBank {
        // create multisig resource
        let multisig = Multisig { participants: IterableTable::new(), approval_threshold, cancellation_threshold, proposals: Vector::empty(), tokens: IterableTable::new() };
        while (!Vector::is_empty(&participants)) {
            let participant = Vector::pop_back(&mut participants);
            IterableTable::add(&mut multisig.participants, participant, true);
        };

        // add to multisig bank
        assert(exists<MultisigBank>(@Multiture), 1000); // NOT_INITIALIZED
        let multisigs = &mut borrow_global_mut<MultisigBank>(@Multiture).multisigs;
        Vector::push_back(multisigs, multisig);
        Vector::length(multisigs) - 1
    }

    public fun deposit_object<T: store>(multisig_id: u64, obj: T) acquires ObjectDepositRecord {
        // validate deposits are enabled for this asset
        assert!(exists<ObjectDepositRecord<T>>(@Multiture), 1000); // ASSET_NOT_SUPPORTED

        // insert object
        let record = borrow_global_mut<ObjectDepositRecord<T>>(@Multiture);
        if (!Table::contains(&mut record.record, multisig_id)) Table::add(&mut record.record, multisig_id, IterableTable::new());
        let objs = Table::borrow_mut(&mut record.record, multisig_id);
        IterableTable::add(objs, record.next_id, obj);
        *&mut record.next_id = record.next_id + 1;
    }

    public fun deposit<AssetType>(multisig_id: u64, coin: Coin<AssetType>) acquires DepositRecord {
        // validate deposits are enabled for this asset
        assert!(exists<DepositRecord<AssetType>>(@Multiture), 1000); // ASSET_NOT_SUPPORTED

        // insert coin (if coin already exists, first remove old coin and combine with new coin before reinserting combined coin)
        let record = &mut borrow_global_mut<DepositRecord<AssetType>>(@Multiture).record;
        if (Table::contains(record, multisig_id)) {
            let old_coin = Table::remove(record, multisig_id);
            Coin::merge(&mut coin, old_coin);
        };
        Table::add(record, multisig_id, coin);
    }

    public fun create_proposal(
        account: &signer,
        multisig_id: u64,
        add_participants: vector<address>,
        remove_participants: vector<address>,
        approve_messages: vector<vector<u8>>,
        withdraw_tokens: vector<PendingTokenWithdrawal>
    ) acquires MultisigBank {
        // get mutable multisig from ID
        assert!(exists<MultisigBank>(@Multiture), 1000); // MULTISIG_BANK_DOES_NOT_EXIST
        let multisigs = &mut borrow_global_mut<MultisigBank>(@Multiture).multisigs;
        assert!(multisig_id <= Vector::length(multisigs), 1000); // MULTISIG_DOES_NOT_EXIST
        let multisig = Vector::borrow_mut(multisigs, multisig_id);

        // add proposal
        let sender = Signer::address_of(account);
        Vector::push_back(&mut multisig.proposals, Proposal {
            creator: sender,
            posted: false,
            votes: Table::new(),
            approval_votes: 0,
            cancellation_votes: 0,
            add_participants,
            remove_participants,
            approve_messages,
            withdraw_tokens
        });
    }

    public fun request_authed_object_withdrawal<T: store>(account: &signer, multisig_id: u64, proposal_id: u64, ids: vector<u64>)
        acquires MultisigBank, PendingAuthedObjectWithdrawalRecord
    {
        // get multisig and proposal from IDs
        assert!(exists<MultisigBank>(@Multiture), 1000); // MULTISIG_BANK_DOES_NOT_EXIST
        let multisigs = &borrow_global<MultisigBank>(@Multiture).multisigs;
        assert!(multisig_id <= Vector::length(multisigs), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposals = &Vector::borrow(multisigs, multisig_id).proposals;
        assert!(proposal_id <= Vector::length(proposals), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposal = Vector::borrow(proposals, proposal_id);

        // make sure proposal not yet posted
        assert!(!proposal.posted, 1000); // PROPOSAL_ALREADY_POSTED

        // validate proposal creator
        let sender = Signer::address_of(account);
        assert!(sender == proposal.creator, 1000); // SIGNER_NOT_PROPOSAL_CREATOR

        // add or update withdrawal request
        assert(exists<PendingAuthedObjectWithdrawalRecord<T>>(@Multiture), 1000); // ASSET_NOT_SUPPORTED
        let record = &mut borrow_global_mut<PendingAuthedObjectWithdrawalRecord<T>>(@Multiture).record;
        let combined_id = ProposalID { multisig_id, proposal_id };
        if (Table::contains(record, combined_id)) {
            Table::remove(record, combined_id);
        };
        Table::add(record, combined_id, ids)
    }

    public fun request_authed_withdrawal<AssetType>(account: &signer, multisig_id: u64, proposal_id: u64, amount: u64)
        acquires MultisigBank, PendingAuthedWithdrawalRecord
    {
        // get multisig and proposal from IDs
        assert!(exists<MultisigBank>(@Multiture), 1000); // MULTISIG_BANK_DOES_NOT_EXIST
        let multisigs = &borrow_global<MultisigBank>(@Multiture).multisigs;
        assert!(multisig_id <= Vector::length(multisigs), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposals = &Vector::borrow(multisigs, multisig_id).proposals;
        assert!(proposal_id <= Vector::length(proposals), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposal = Vector::borrow(proposals, proposal_id);

        // make sure proposal not yet posted
        assert!(!proposal.posted, 1000); // PROPOSAL_ALREADY_POSTED

        // validate proposal creator
        let sender = Signer::address_of(account);
        assert!(sender == proposal.creator, 1000); // SIGNER_NOT_PROPOSAL_CREATOR

        // add or update withdrawal request
        assert(exists<PendingAuthedWithdrawalRecord<AssetType>>(@Multiture), 1000); // ASSET_NOT_SUPPORTED
        let record = &mut borrow_global_mut<PendingAuthedWithdrawalRecord<AssetType>>(@Multiture).record;
        let combined_id = ProposalID { multisig_id, proposal_id };
        if (Table::contains(record, combined_id)) {
            Table::remove(record, combined_id);
        };
        Table::add(record, combined_id, amount)
    }

    public fun request_withdrawal_transfer<AssetType>(account: &signer, multisig_id: u64, proposal_id: u64, recipient: address, amount: u64)
        acquires MultisigBank, PendingWithdrawalTransferRecord
    {
        // get multisig and proposal from IDs
        assert!(exists<MultisigBank>(@Multiture), 1000); // MULTISIG_BANK_DOES_NOT_EXIST
        let multisigs = &borrow_global<MultisigBank>(@Multiture).multisigs;
        assert!(multisig_id <= Vector::length(multisigs), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposals = &Vector::borrow(multisigs, multisig_id).proposals;
        assert!(proposal_id <= Vector::length(proposals), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposal = Vector::borrow(proposals, proposal_id);

        // make sure proposal not yet posted
        assert!(!proposal.posted, 1000); // PROPOSAL_ALREADY_POSTED

        // validate proposal creator
        let sender = Signer::address_of(account);
        assert!(sender == proposal.creator, 1000); // SIGNER_NOT_PROPOSAL_CREATOR

        // add or update withdrawal request
        assert(exists<PendingWithdrawalTransferRecord<AssetType>>(@Multiture), 1000); // ASSET_NOT_SUPPORTED
        let record = &mut borrow_global_mut<PendingWithdrawalTransferRecord<AssetType>>(@Multiture).record;
        let combined_id = ProposalID { multisig_id, proposal_id };
        if (Table::contains(record, combined_id)) {
            Table::remove(record, combined_id);
        };
        let transfer_data = PendingWithdrawalTransfer { recipient, amount };
        Table::add(record, combined_id, transfer_data)
    }

    public fun post_proposal(account: &signer, multisig_id: u64, proposal_id: u64): AuthToken acquires MultisigBank {
        // get multisig and proposal from IDs
        assert!(exists<MultisigBank>(@Multiture), 1000); // MULTISIG_BANK_DOES_NOT_EXIST
        let multisigs = &mut borrow_global_mut<MultisigBank>(@Multiture).multisigs;
        assert!(multisig_id <= Vector::length(multisigs), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposals = &mut Vector::borrow_mut(multisigs, multisig_id).proposals;
        assert!(proposal_id <= Vector::length(proposals), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposal = Vector::borrow_mut(proposals, proposal_id);

        // make sure proposal not yet posted
        assert!(!*&proposal.posted, 1000); // PROPOSAL_ALREADY_POSTED

        // validate proposal creator
        let sender = Signer::address_of(account);
        assert!(sender == *&proposal.creator, 1000); // SIGNER_NOT_PROPOSAL_CREATOR

        // mark proposal as posted
        *&mut proposal.posted = true;

        // return auth token
        AuthToken { multisig_id, proposal_id }
    }

    public fun cast_vote(account: &signer, multisig_id: u64, proposal_id: u64, vote: bool) acquires MultisigBank {
        // get multisig and proposal from IDs
        assert!(exists<MultisigBank>(@Multiture), 1000); // MULTISIG_BANK_DOES_NOT_EXIST
        let multisigs = &mut borrow_global_mut<MultisigBank>(@Multiture).multisigs;
        assert!(multisig_id <= Vector::length(multisigs), 1000); // MULTISIG_DOES_NOT_EXIST
        let multisig = Vector::borrow_mut(multisigs, multisig_id);
        assert!(proposal_id <= Vector::length(&multisig.proposals), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposal = Vector::borrow_mut(&mut multisig.proposals, proposal_id);

        // make sure proposal posted but not cancelled
        assert!(*&proposal.posted, 1000); // PROPOSAL_NOT_POSTED
        assert!(*&proposal.cancellation_votes < *&multisig.cancellation_threshold, 1000); // PROPOSAL_ALREADY_CANCELED

        // check participant is part of multisig
        let sender = Signer::address_of(account);
        assert!(IterableTable::contains(&multisig.participants, sender) && *IterableTable::borrow(&multisig.participants, sender), 1000); // UNAUTHORIZED_PARTICIPANT

        // remove old vote if necessary
        if (Table::contains(&proposal.votes, sender)) {
            let old_vote = Table::remove(&mut proposal.votes, sender);
            assert!(vote != old_vote, 1000); // VOTE_NOT_CHANGED
            if (old_vote) *&mut proposal.approval_votes = *&proposal.approval_votes - 1
            else *&mut proposal.cancellation_votes = *&proposal.cancellation_votes - 1;
        };

        // cast new vote
        Table::add(&mut proposal.votes, sender, vote);
        if (vote) *&mut proposal.approval_votes = *&proposal.approval_votes + 1
        else *&mut proposal.cancellation_votes = *&proposal.cancellation_votes + 1;
    }

    public fun execute_participant_changes(multisig_id: u64, proposal_id: u64) acquires MultisigBank {
        // get multisig and proposal from IDs
        assert!(exists<MultisigBank>(@Multiture), 1000); // MULTISIG_BANK_DOES_NOT_EXIST
        let multisigs = &mut borrow_global_mut<MultisigBank>(@Multiture).multisigs;
        assert!(multisig_id <= Vector::length(multisigs), 1000); // MULTISIG_DOES_NOT_EXIST
        let multisig = Vector::borrow_mut(multisigs, multisig_id);
        assert!(proposal_id <= Vector::length(&multisig.proposals), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposal = Vector::borrow_mut(&mut multisig.proposals, proposal_id);

        // make sure proposal has enough approval votes but is not cancelled
        assert!(proposal.approval_votes >= multisig.approval_threshold, 1000); // NOT_ENOUGH_APPROVALS
        assert!(proposal.cancellation_votes < multisig.cancellation_threshold, 1000); // PROPOSAL_ALREADY_CANCELED

        // make sure there are changes to be made
        assert!(!Vector::is_empty(&proposal.remove_participants) || !Vector::is_empty(&proposal.add_participants), 1000); // NO_PENDING_PARTICIPANT_CHANGES

        // execute participant removals
        while (!Vector::is_empty(&proposal.remove_participants)) {
            let participant = Vector::pop_back(&mut proposal.remove_participants);
            IterableTable::remove(&mut multisig.participants, participant);
        };

        // execute participant additions
        while (!Vector::is_empty(&proposal.add_participants)) {
            let participant = Vector::pop_back(&mut proposal.add_participants);
            IterableTable::add(&mut multisig.participants, participant, true);
        };
    }

    // note that this only executes Token withdrawals but not Coin withdrawals
    public fun execute_token_withdrawals(dummy: &signer, multisig_id: u64, proposal_id: u64) acquires MultisigBank {
        // get multisig and proposal from IDs
        assert!(exists<MultisigBank>(@Multiture), 1000); // MULTISIG_BANK_DOES_NOT_EXIST
        let multisigs = &mut borrow_global_mut<MultisigBank>(@Multiture).multisigs;
        assert!(multisig_id <= Vector::length(multisigs), 1000); // MULTISIG_DOES_NOT_EXIST
        let multisig = Vector::borrow_mut(multisigs, multisig_id);
        assert!(proposal_id <= Vector::length(&multisig.proposals), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposal = Vector::borrow_mut(&mut multisig.proposals, proposal_id);

        // make sure proposal has enough approval votes but is not cancelled
        assert!(proposal.approval_votes >= multisig.approval_threshold, 1000); // NOT_ENOUGH_APPROVALS
        assert!(proposal.cancellation_votes < multisig.cancellation_threshold, 1000); // PROPOSAL_ALREADY_CANCELED

        // execute token withdrawals
        while (!Vector::is_empty(&proposal.withdraw_tokens)) {
            let pending_token_withdrawal = Vector::pop_back(&mut proposal.withdraw_tokens);
            let multisig_token = IterableTable::remove(&mut multisig.tokens, pending_token_withdrawal.tokenId);
            Token::deposit_token(dummy, multisig_token);
            let tokens_available = Token::balance_of(Signer::address_of(dummy), pending_token_withdrawal.tokenId);
            assert!(tokens_available >= pending_token_withdrawal.value, 1000); // INSUFFICIENT_TOKENS

            if (tokens_available > pending_token_withdrawal.value) {
                let change = Token::withdraw_token(dummy, pending_token_withdrawal.tokenId, tokens_available - pending_token_withdrawal.value);
                IterableTable::add(&mut multisig.tokens, pending_token_withdrawal.tokenId, change);
            };

            Token::transfer(dummy, pending_token_withdrawal.tokenId, pending_token_withdrawal.recipient, pending_token_withdrawal.value);
        };
    }

    public fun withdraw_to<AssetType>(multisig_id: u64, proposal_id: u64)
        acquires MultisigBank, PendingWithdrawalTransferRecord, DepositRecord
    {
        // get multisig and proposal from IDs
        assert!(exists<MultisigBank>(@Multiture), 1000); // MULTISIG_BANK_DOES_NOT_EXIST
        let multisigs = &mut borrow_global_mut<MultisigBank>(@Multiture).multisigs;
        assert!(multisig_id <= Vector::length(multisigs), 1000); // MULTISIG_DOES_NOT_EXIST
        let multisig = Vector::borrow_mut(multisigs, multisig_id);
        assert!(proposal_id <= Vector::length(&multisig.proposals), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposal = Vector::borrow_mut(&mut multisig.proposals, proposal_id);

        // make sure proposal has enough approval votes but is not cancelled
        assert!(proposal.approval_votes >= multisig.approval_threshold, 1000); // NOT_ENOUGH_APPROVALS
        assert!(proposal.cancellation_votes < multisig.cancellation_threshold, 1000); // PROPOSAL_ALREADY_CANCELED

        // get withdrawal amount and remove pending withdrawal from map
        assert!(exists<PendingWithdrawalTransferRecord<AssetType>>(@Multiture), 1000); // ASSET_NOT_SUPPORTED
        let record = &mut borrow_global_mut<PendingWithdrawalTransferRecord<AssetType>>(@Multiture).record;
        let combined_id = ProposalID { multisig_id, proposal_id };
        assert!(Table::contains(record, combined_id), 1000); // ASSET_NOT_IN_PROPOSAL
        let transfer_data = Table::remove(record, combined_id);

        // withdraw tokens (if less than total, withdraw and reinsert)
        let record = &mut borrow_global_mut<DepositRecord<AssetType>>(@Multiture).record;
        assert!(Table::contains(record, multisig_id), 1000); // INSUFFICIENT_FUNDS
        let multisig_coin = Table::remove(record, multisig_id);
        let funds_available = Coin::value(&multisig_coin);
        assert!(funds_available >= transfer_data.amount, 1000); // INSUFFICIENT_FUNDS

        if (funds_available > transfer_data.amount) {
            let coin_out = Coin::extract(&mut multisig_coin, transfer_data.amount);
            Table::add(record, multisig_id, multisig_coin);
            Coin::deposit(transfer_data.recipient, coin_out)
        } else {
            Coin::deposit(transfer_data.recipient, multisig_coin)
        }
    }

    public fun withdraw<AssetType>(auth_token: &AuthToken): Coin<AssetType>
        acquires MultisigBank, PendingAuthedWithdrawalRecord, DepositRecord
    {
        // get multisig and proposal from IDs in AuthToken
        assert!(exists<MultisigBank>(@Multiture), 1000); // MULTISIG_BANK_DOES_NOT_EXIST
        let multisigs = &borrow_global<MultisigBank>(@Multiture).multisigs;
        assert!(auth_token.multisig_id <= Vector::length(multisigs), 1000); // MULTISIG_DOES_NOT_EXIST
        let multisig = Vector::borrow(multisigs, auth_token.multisig_id);
        assert!(auth_token.proposal_id <= Vector::length(&multisig.proposals), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposal = Vector::borrow(&multisig.proposals, auth_token.proposal_id);

        // make sure proposal has enough votes
        assert!(proposal.approval_votes >= multisig.approval_threshold, 1000); // PROPOSAL_NOT_APPROVED
        assert!(proposal.cancellation_votes < multisig.cancellation_threshold, 1000); // PROPOSAL_ALREADY_CANCELED

        // get withdrawal amount and remove pending withdrawal from map
        assert!(exists<PendingAuthedWithdrawalRecord<AssetType>>(@Multiture), 1000); // ASSET_NOT_SUPPORTED
        let record = &mut borrow_global_mut<PendingAuthedWithdrawalRecord<AssetType>>(@Multiture).record;
        let combined_id = ProposalID { multisig_id: auth_token.multisig_id, proposal_id: auth_token.proposal_id };
        assert!(Table::contains(record, combined_id), 1000); // ASSET_NOT_IN_PROPOSAL
        let withdrawal_amount = Table::remove(record, combined_id);

        // withdraw tokens (if less than total, withdraw and reinsert)
        let record = &mut borrow_global_mut<DepositRecord<AssetType>>(@Multiture).record;
        assert!(Table::contains(record, auth_token.multisig_id), 1000); // INSUFFICIENT_FUNDS
        let multisig_coin = Table::remove(record, auth_token.multisig_id);
        let funds_available = Coin::value(&multisig_coin);
        assert!(funds_available >= withdrawal_amount, 1000); // INSUFFICIENT_FUNDS

        if (funds_available > withdrawal_amount) {
            let coin_out = Coin::extract(&mut multisig_coin, withdrawal_amount);
            Table::add(record, auth_token.multisig_id, multisig_coin);
            coin_out
        } else {
            multisig_coin
        }
    }

    public fun withdraw_objects<T: store>(auth_token: &AuthToken): vector<T>
        acquires MultisigBank, PendingAuthedObjectWithdrawalRecord, ObjectDepositRecord
    {
        // get multisig and proposal from IDs in AuthToken
        assert!(exists<MultisigBank>(@Multiture), 1000); // MULTISIG_BANK_DOES_NOT_EXIST
        let multisigs = &borrow_global<MultisigBank>(@Multiture).multisigs;
        assert!(auth_token.multisig_id <= Vector::length(multisigs), 1000); // MULTISIG_DOES_NOT_EXIST
        let multisig = Vector::borrow(multisigs, auth_token.multisig_id);
        assert!(auth_token.proposal_id <= Vector::length(&multisig.proposals), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposal = Vector::borrow(&multisig.proposals, auth_token.proposal_id);

        // make sure proposal has enough votes
        assert!(proposal.approval_votes >= multisig.approval_threshold, 1000); // PROPOSAL_NOT_APPROVED
        assert!(proposal.cancellation_votes < multisig.cancellation_threshold, 1000); // PROPOSAL_ALREADY_CANCELED

        // get object IDs to be withdrawn and remove pending withdrawal from map
        assert!(exists<PendingAuthedObjectWithdrawalRecord<T>>(@Multiture), 1000); // OBJECT_TYPE_NOT_SUPPORTED
        let record = &mut borrow_global_mut<PendingAuthedObjectWithdrawalRecord<T>>(@Multiture).record;
        let combined_id = ProposalID { multisig_id: auth_token.multisig_id, proposal_id: auth_token.proposal_id };
        assert!(Table::contains(record, combined_id), 1000); // OBJECT_TYPE_NOT_IN_PROPOSAL
        let object_ids = Table::remove(record, combined_id);

        // withdraw objects
        let record = &mut borrow_global_mut<ObjectDepositRecord<T>>(@Multiture).record;
        assert!(Table::contains(record, auth_token.multisig_id), 1000); // RECORD_NOT_FOUND
        let objects = Table::borrow_mut(record, auth_token.multisig_id);
        let output = Vector::empty<T>();

        while (!Vector::is_empty(&object_ids)) {
            let object = IterableTable::remove(objects, Vector::pop_back(&mut object_ids));
            Vector::push_back(&mut output, object);
        };

        output
    }
}
