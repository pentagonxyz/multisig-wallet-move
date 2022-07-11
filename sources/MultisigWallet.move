module Multiture::MultisigWallet {
    use Std::Signer;
    use Std::Vector;

    use AptosFramework::Coin::{Self, Coin};
    use AptosFramework::IterableTable::{Self, IterableTable};
    use AptosFramework::Table::{Self, Table};

    struct MultisigBank has key {
        multisigs: vector<Multisig>
    }

    struct Multisig has store {
        participants: IterableTable<address, bool>,
        approval_threshold: u64,
        cancellation_threshold: u64,
        proposals: vector<Proposal>
    }

    struct Proposal has store {
        creator: address,
        posted: bool,
        votes: Table<address, bool>,
        approval_votes: u64,
        cancellation_votes: u64,
        approve_messages: vector<vector<u8>>,
        add_participants: vector<address>,
        remove_participants: vector<address>
    }

    struct AuthToken has copy, drop, store {
        multisig_initiator: address,
        multisig_id: u64,
        proposal_id: u64
    }

    struct DepositRecord<phantom AssetType> has key {
        record: Table<u64, Coin<AssetType>>
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

    public fun create_multisig(account: &signer, participants: vector<address>, approval_threshold: u64, cancellation_threshold: u64): u64 acquires MultisigBank {
        // create multisig resource
        let multisig = Multisig { participants: IterableTable::new(), approval_threshold, cancellation_threshold, proposals: Vector::empty() };
        while (!Vector::is_empty(&participants)) {
            let participant = Vector::pop_back(&mut participants);
            IterableTable::add(&mut multisig.participants, participant, true);
        };

        // create multisig bank or add to existing
        let sender = Signer::address_of(account);
        if (exists<MultisigBank>(sender)) {
            let multisigs = &mut borrow_global_mut<MultisigBank>(sender).multisigs;
            Vector::push_back(multisigs, multisig);
            Vector::length(multisigs) - 1
        } else {
            move_to(account, MultisigBank { multisigs: Vector::singleton<Multisig>(multisig) });
            0
        }
    }

    public fun enable_deposits<AssetType>(account: &signer) {
        // validate deposits are not yet enabled
        let sender = Signer::address_of(account);
        assert!(!exists<DepositRecord<AssetType>>(sender), 1000); // DEPOSITS_ALREADY_ENABLED

        // add deposit record and withdrawal request record
        move_to(account, DepositRecord<AssetType> { record: Table::new() });
        move_to(account, PendingAuthedWithdrawalRecord<AssetType> { record: Table::new() });
        move_to(account, PendingWithdrawalTransferRecord<AssetType> { record: Table::new() });
    }

    public fun deposit<AssetType>(multisig_initiator: address, multisig_id: u64, coin: Coin<AssetType>) acquires DepositRecord {
        // validate deposits are enabled for this asset
        assert!(exists<DepositRecord<AssetType>>(multisig_initiator), 1000); // ASSET_NOT_SUPPORTED

        // insert coin (if coin already exists, first remove old coin and combine with new coin before reinserting combined coin)
        let record = &mut borrow_global_mut<DepositRecord<AssetType>>(multisig_initiator).record;
        if (Table::contains(record, multisig_id)) {
            let old_coin = Table::remove(record, multisig_id);
            Coin::merge(&mut coin, old_coin);
        };
        Table::add(record, multisig_id, coin);
    }

    public fun create_proposal(
        account: &signer,
        multisig_initiator: address,
        multisig_id: u64,
        add_participants: vector<address>,
        remove_participants: vector<address>,
        approve_messages: vector<vector<u8>>
    ) acquires MultisigBank {
        // get mutable multisig from ID
        assert!(exists<MultisigBank>(multisig_initiator), 1000); // MULTISIG_BANK_DOES_NOT_EXIST
        let multisigs = &mut borrow_global_mut<MultisigBank>(multisig_initiator).multisigs;
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
            approve_messages
        });
    }

    public fun request_authed_withdrawal<AssetType>(account: &signer, multisig_initiator: address, multisig_id: u64, proposal_id: u64, amount: u64)
        acquires MultisigBank, PendingAuthedWithdrawalRecord
    {
        // get multisig and proposal from IDs
        assert!(exists<MultisigBank>(multisig_initiator), 1000); // MULTISIG_BANK_DOES_NOT_EXIST
        let multisigs = &borrow_global<MultisigBank>(multisig_initiator).multisigs;
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
        assert(exists<PendingAuthedWithdrawalRecord<AssetType>>(multisig_initiator), 1000); // ASSET_NOT_SUPPORTED
        let record = &mut borrow_global_mut<PendingAuthedWithdrawalRecord<AssetType>>(multisig_initiator).record;
        let combined_id = ProposalID { multisig_id, proposal_id };
        if (Table::contains(record, combined_id)) {
            Table::remove(record, combined_id);
        };
        Table::add(record, combined_id, amount)
    }

    public fun request_withdrawal_transfer<AssetType>(account: &signer, multisig_initiator: address, multisig_id: u64, proposal_id: u64, recipient: address, amount: u64)
        acquires MultisigBank, PendingWithdrawalTransferRecord
    {
        // get multisig and proposal from IDs
        assert!(exists<MultisigBank>(multisig_initiator), 1000); // MULTISIG_BANK_DOES_NOT_EXIST
        let multisigs = &borrow_global<MultisigBank>(multisig_initiator).multisigs;
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
        assert(exists<PendingWithdrawalTransferRecord<AssetType>>(multisig_initiator), 1000); // ASSET_NOT_SUPPORTED
        let record = &mut borrow_global_mut<PendingWithdrawalTransferRecord<AssetType>>(multisig_initiator).record;
        let combined_id = ProposalID { multisig_id, proposal_id };
        if (Table::contains(record, combined_id)) {
            Table::remove(record, combined_id);
        };
        let transfer_data = PendingWithdrawalTransfer { recipient, amount };
        Table::add(record, combined_id, transfer_data)
    }

    public fun post_proposal(account: &signer, multisig_initiator: address, multisig_id: u64, proposal_id: u64): AuthToken acquires MultisigBank {
        // get multisig and proposal from IDs
        assert!(exists<MultisigBank>(multisig_initiator), 1000); // MULTISIG_BANK_DOES_NOT_EXIST
        let multisigs = &mut borrow_global_mut<MultisigBank>(multisig_initiator).multisigs;
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
        AuthToken { multisig_initiator, multisig_id, proposal_id }
    }

    public fun cast_vote(account: &signer, multisig_initiator: address, multisig_id: u64, proposal_id: u64, vote: bool) acquires MultisigBank {
        // get multisig and proposal from IDs
        assert!(exists<MultisigBank>(multisig_initiator), 1000); // MULTISIG_BANK_DOES_NOT_EXIST
        let multisigs = &mut borrow_global_mut<MultisigBank>(multisig_initiator).multisigs;
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

    public fun execute_participant_changes(multisig_initiator: address, multisig_id: u64, proposal_id: u64) acquires MultisigBank {
        // get multisig and proposal from IDs
        assert!(exists<MultisigBank>(multisig_initiator), 1000); // MULTISIG_BANK_DOES_NOT_EXIST
        let multisigs = &mut borrow_global_mut<MultisigBank>(multisig_initiator).multisigs;
        assert!(multisig_id <= Vector::length(multisigs), 1000); // MULTISIG_DOES_NOT_EXIST
        let multisig = Vector::borrow_mut(multisigs, multisig_id);
        assert!(proposal_id <= Vector::length(&multisig.proposals), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposal = Vector::borrow_mut(&mut multisig.proposals, proposal_id);

        // make sure proposal has enough approval votes but is not cancelled
        assert!(proposal.approval_votes >= multisig.approval_threshold, 1000); // NOT_ENOUGH_APPROVALS
        assert!(proposal.cancellation_votes < multisig.cancellation_threshold, 1000); // PROPOSAL_ALREADY_CANCELED

        // make sure there are changes to be made
        assert!(!Vector::is_empty(&proposal.remove_participants) || !Vector::is_empty(&proposal.add_participants), 1000); // NO_PENDING_PARTICIPANT_CHANGES

        // execute removals
        while (!Vector::is_empty(&proposal.remove_participants)) {
            let participant = Vector::pop_back(&mut proposal.remove_participants);
            IterableTable::remove(&mut multisig.participants, participant);
        };

        // execute additions
        while (!Vector::is_empty(&proposal.add_participants)) {
            let participant = Vector::pop_back(&mut proposal.add_participants);
            IterableTable::add(&mut multisig.participants, participant, true);
        };
    }

    public fun withdraw_to<AssetType>(multisig_initiator: address, multisig_id: u64, proposal_id: u64)
        acquires MultisigBank, PendingWithdrawalTransferRecord, DepositRecord
    {
        // get multisig and proposal from IDs
        assert!(exists<MultisigBank>(multisig_initiator), 1000); // MULTISIG_BANK_DOES_NOT_EXIST
        let multisigs = &mut borrow_global_mut<MultisigBank>(multisig_initiator).multisigs;
        assert!(multisig_id <= Vector::length(multisigs), 1000); // MULTISIG_DOES_NOT_EXIST
        let multisig = Vector::borrow_mut(multisigs, multisig_id);
        assert!(proposal_id <= Vector::length(&multisig.proposals), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposal = Vector::borrow_mut(&mut multisig.proposals, proposal_id);

        // make sure proposal has enough approval votes but is not cancelled
        assert!(proposal.approval_votes >= multisig.approval_threshold, 1000); // NOT_ENOUGH_APPROVALS
        assert!(proposal.cancellation_votes < multisig.cancellation_threshold, 1000); // PROPOSAL_ALREADY_CANCELED

        // get withdrawal amount and remove pending withdrawal from map
        assert!(exists<PendingWithdrawalTransferRecord<AssetType>>(multisig_initiator), 1000); // ASSET_NOT_SUPPORTED
        let record = &mut borrow_global_mut<PendingWithdrawalTransferRecord<AssetType>>(multisig_initiator).record;
        let combined_id = ProposalID { multisig_id, proposal_id };
        assert!(Table::contains(record, combined_id), 1000); // ASSET_NOT_IN_PROPOSAL
        let transfer_data = Table::remove(record, combined_id);

        // withdraw tokens (if less than total, withdraw and reinsert)
        let record = &mut borrow_global_mut<DepositRecord<AssetType>>(multisig_initiator).record;
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
        assert!(exists<MultisigBank>(auth_token.multisig_initiator), 1000); // MULTISIG_BANK_DOES_NOT_EXIST
        let multisigs = &borrow_global<MultisigBank>(auth_token.multisig_initiator).multisigs;
        assert!(auth_token.multisig_id <= Vector::length(multisigs), 1000); // MULTISIG_DOES_NOT_EXIST
        let multisig = Vector::borrow(multisigs, auth_token.multisig_id);
        assert!(auth_token.proposal_id <= Vector::length(&multisig.proposals), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposal = Vector::borrow(&multisig.proposals, auth_token.proposal_id);

        // make sure proposal has enough votes
        assert!(proposal.approval_votes >= multisig.approval_threshold, 1000); // PROPOSAL_NOT_APPROVED
        assert!(proposal.cancellation_votes < multisig.cancellation_threshold, 1000); // PROPOSAL_ALREADY_CANCELED

        // get withdrawal amount and remove pending withdrawal from map
        assert!(exists<PendingAuthedWithdrawalRecord<AssetType>>(auth_token.multisig_initiator), 1000); // ASSET_NOT_SUPPORTED
        let record = &mut borrow_global_mut<PendingAuthedWithdrawalRecord<AssetType>>(auth_token.multisig_initiator).record;
        let combined_id = ProposalID { multisig_id: auth_token.multisig_id, proposal_id: auth_token.proposal_id };
        assert!(Table::contains(record, combined_id), 1000); // ASSET_NOT_IN_PROPOSAL
        let withdrawal_amount = Table::remove(record, combined_id);

        // withdraw tokens (if less than total, withdraw and reinsert)
        let record = &mut borrow_global_mut<DepositRecord<AssetType>>(auth_token.multisig_initiator).record;
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
}
