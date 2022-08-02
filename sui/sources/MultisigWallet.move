module Multiture::MultisigWallet {
    use std::signer;
    use std::vector;

    use sui::coin::{Self, Coin};
    use sui::object::{Self, ID, Info};
    use sui::transfer;
    use sui::tx_context::TxContext;
    use sui::vec_map::{Self, VecMap};

    struct Multisig has key {
        info: Info,
        participants: VecMap<address, bool>,
        approval_threshold: u64,
        cancellation_threshold: u64,
        proposals: vector<Proposal>
    }

    struct Proposal has store {
        creator: address,
        posted: bool,
        votes: VecMap<address, bool>,
        approval_votes: u64,
        cancellation_votes: u64,
        approve_messages: vector<vector<u8>>,
        add_participants: vector<address>,
        remove_participants: vector<address>,
    }

    struct AuthToken has copy, drop, store {
        multisig_id: ID,
        proposal_id: u64
    }

    struct ObjectDepositRecord<T> has key {
        info: Info,
        record: VecMap<ID, ObjectDeposit<T>>
    }

    struct ObjectDeposit<T> has store {
        objects: VecMap<u64, T>,
        next_id: u64
    }

    struct DepositRecord<phantom AssetType> has key {
        info: Info,
        record: VecMap<ID, Coin<AssetType>>
    }

    struct PendingAuthedObjectWithdrawalRecord<phantom T> has key {
        info: Info,
        record: VecMap<ProposalID, vector<u64>>
    }

    struct PendingObjectTransferWithdrawalRecord<phantom T> has key {
        info: Info,
        record: VecMap<ProposalID, vector<PendingObjectWithdrawalTransfer>>
    }

    struct PendingAuthedWithdrawalRecord<phantom AssetType> has key {
        info: Info,
        record: VecMap<ProposalID, u64>
    }

    struct PendingWithdrawalTransferRecord<phantom AssetType> has key {
        info: Info,
        record: VecMap<ProposalID, PendingWithdrawalTransfer>
    }

    struct ProposalID has copy, drop, store {
        multisig_id: ID,
        proposal_id: u64
    }

    struct PendingObjectWithdrawalTransfer has drop, store {
        recipient: address,
        object_id: u64
    }

    struct PendingWithdrawalTransfer has drop, store {
        recipient: address,
        amount: u64
    }

    public entry fun enable_deposits<AssetType>(ctx: &mut TxContext) {
        // add deposit record and withdrawal request record
        transfer::share_object(DepositRecord<AssetType> { info: object::new(ctx), record: vec_map::empty() });
        transfer::share_object(PendingAuthedWithdrawalRecord<AssetType> { info: object::new(ctx), record: vec_map::empty() });
        transfer::share_object(PendingWithdrawalTransferRecord<AssetType> { info: object::new(ctx), record: vec_map::empty() });
    }

    public entry fun enable_object_deposits<T: store>(ctx: &mut TxContext) {
        // add deposit record and withdrawal request record
        transfer::share_object(ObjectDepositRecord<T> { info: object::new(ctx), record: vec_map::empty() });
        transfer::share_object(PendingAuthedObjectWithdrawalRecord<T> { info: object::new(ctx), record: vec_map::empty() });
        transfer::share_object(PendingObjectTransferWithdrawalRecord<T> { info: object::new(ctx), record: vec_map::empty() });
    }

    public entry fun create_multisig(participants: vector<address>, approval_threshold: u64, cancellation_threshold: u64, ctx: &mut TxContext) {
        // create multisig resource
        let multisig = Multisig {
            info: object::new(ctx),
            participants: vec_map::empty(),
            approval_threshold,
            cancellation_threshold,
            proposals: vector::empty()
        };
        while (!vector::is_empty(&participants)) {
            let participant = vector::pop_back(&mut participants);
            vec_map::insert(&mut multisig.participants, participant, true);
        };
        transfer::share_object(multisig)
    }

    public fun deposit_object<T: store>(multisig: &Multisig, record: &mut ObjectDepositRecord<T>, obj: T) {
        // insert object
        let multisig_id = object::id(multisig);
        let record_inner = &mut record.record;
        if (!vec_map::contains(record_inner, multisig_id)) vec_map::insert(record_inner, *multisig_id, ObjectDeposit { objects: vec_map::empty(), next_id: 0 });
        let deposits = vec_map::get_mut(record_inner, multisig_id);
        vec_map::insert(&mut deposits.objects, deposits.next_id, obj);
        *&mut deposits.next_id = deposits.next_id + 1;
    }

    public fun deposit<AssetType>(multisig: &Multisig, record: &mut DepositRecord<AssetType>, coin: Coin<AssetType>) {
        // insert coin (if coin already exists, first remove old coin and combine with new coin before reinserting combined coin)
        let multisig_id = object::id(multisig);
        let record_inner = &mut record.record;
        if (vec_map::contains(record_inner, multisig_id)) {
            let (_, old_coin) = vec_map::remove(record_inner, multisig_id);
            coin::join(&mut coin, old_coin);
        };
        vec_map::insert(record_inner, *multisig_id, coin);
    }

    public fun create_proposal(
        account: &signer,
        multisig: &mut Multisig,
        add_participants: vector<address>,
        remove_participants: vector<address>,
        approve_messages: vector<vector<u8>>
    ) {
        // add proposal
        let sender = signer::address_of(account);
        assert!(vec_map::contains(&multisig.participants, &sender) && *vec_map::get(&multisig.participants, &sender), 1000); // SENDER_NOT_AUTHORIZED
        vector::push_back(&mut multisig.proposals, Proposal {
            creator: sender,
            posted: false,
            votes: vec_map::empty(),
            approval_votes: 0,
            cancellation_votes: 0,
            add_participants,
            remove_participants,
            approve_messages
        });
    }

    public fun request_authed_object_withdrawal<T: store>(
        account: &signer,
        multisig: &Multisig,
        record: &mut PendingAuthedObjectWithdrawalRecord<T>,
        proposal_id: u64,
        ids: vector<u64>
    ) {
        // get multisig ID and proposal from ID
        let multisig_id = object::id(multisig);
        let proposals = &multisig.proposals;
        assert!(proposal_id <= vector::length(proposals), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposal = vector::borrow(proposals, proposal_id);

        // make sure proposal not yet posted
        assert!(!proposal.posted, 1000); // PROPOSAL_ALREADY_POSTED

        // validate proposal creator
        let sender = signer::address_of(account);
        assert!(sender == proposal.creator, 1000); // SIGNER_NOT_PROPOSAL_CREATOR

        // add or update withdrawal request
        let combined_id = ProposalID { multisig_id: *multisig_id, proposal_id };
        let record_inner = &mut record.record;
        if (vec_map::contains(record_inner, &combined_id)) {
            vec_map::remove(record_inner, &combined_id);
        };
        vec_map::insert(record_inner, combined_id, ids)
    }

    public fun request_authed_withdrawal<AssetType>(
        account: &signer,
        multisig: &Multisig,
        record: &mut PendingAuthedWithdrawalRecord<AssetType>,
        proposal_id: u64,
        amount: u64
    ) {
        // get multisig ID and proposal from ID
        let multisig_id = object::id(multisig);
        let proposals = &multisig.proposals;
        assert!(proposal_id <= vector::length(proposals), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposal = vector::borrow(proposals, proposal_id);

        // make sure proposal not yet posted
        assert!(!proposal.posted, 1000); // PROPOSAL_ALREADY_POSTED

        // validate proposal creator
        let sender = signer::address_of(account);
        assert!(sender == proposal.creator, 1000); // SIGNER_NOT_PROPOSAL_CREATOR

        // add or update withdrawal request
        let combined_id = ProposalID { multisig_id: *multisig_id, proposal_id };
        let record_inner = &mut record.record;
        if (vec_map::contains(record_inner, &combined_id)) {
            vec_map::remove(record_inner, &combined_id);
        };
        vec_map::insert(record_inner, combined_id, amount)
    }

    public fun request_withdrawal_transfer<AssetType>(
        account: &signer,
        multisig: &Multisig,
        record: &mut PendingWithdrawalTransferRecord<AssetType>,
        proposal_id: u64,
        recipient: address,
        amount: u64
    ) {
        // get multisig ID and proposal from ID
        let multisig_id = object::id(multisig);
        let proposals = &multisig.proposals;
        assert!(proposal_id <= vector::length(proposals), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposal = vector::borrow(proposals, proposal_id);

        // make sure proposal not yet posted
        assert!(!proposal.posted, 1000); // PROPOSAL_ALREADY_POSTED

        // validate proposal creator
        let sender = signer::address_of(account);
        assert!(sender == proposal.creator, 1000); // SIGNER_NOT_PROPOSAL_CREATOR

        // add or update withdrawal request
        let combined_id = ProposalID { multisig_id: *multisig_id, proposal_id };
        let record_inner = &mut record.record;
        if (vec_map::contains(record_inner, &combined_id)) {
            vec_map::remove(record_inner, &combined_id);
        };
        let transfer_data = PendingWithdrawalTransfer { recipient, amount };
        vec_map::insert(record_inner, combined_id, transfer_data)
    }

    public fun post_proposal(account: &signer, multisig: &mut Multisig, proposal_id: u64): AuthToken {
        // get multisig ID and proposal from ID
        let proposals = &mut multisig.proposals;
        assert!(proposal_id <= vector::length(proposals), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposal = vector::borrow_mut(proposals, proposal_id);

        // make sure proposal not yet posted
        assert!(!*&proposal.posted, 1000); // PROPOSAL_ALREADY_POSTED

        // validate proposal creator
        let sender = signer::address_of(account);
        assert!(sender == *&proposal.creator, 1000); // SIGNER_NOT_PROPOSAL_CREATOR

        // mark proposal as posted
        *&mut proposal.posted = true;

        // return auth token
        AuthToken { multisig_id: *object::id(multisig), proposal_id }
    }

    public fun cast_vote(account: &signer, multisig: &mut Multisig, proposal_id: u64, vote: bool) {
        // get multisig ID and proposal from ID
        let proposals = &mut multisig.proposals;
        assert!(proposal_id <= vector::length(proposals), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposal = vector::borrow_mut(proposals, proposal_id);

        // make sure proposal posted but not cancelled
        assert!(*&proposal.posted, 1000); // PROPOSAL_NOT_POSTED
        assert!(*&proposal.cancellation_votes < *&multisig.cancellation_threshold, 1000); // PROPOSAL_ALREADY_CANCELED

        // check participant is part of multisig
        let sender = signer::address_of(account);
        assert!(vec_map::contains(&multisig.participants, &sender) && *vec_map::get(&multisig.participants, &sender), 1000); // UNAUTHORIZED_PARTICIPANT

        // remove old vote if necessary
        if (vec_map::contains(&proposal.votes, &sender)) {
            let (_, old_vote) = vec_map::remove(&mut proposal.votes, &sender);
            assert!(vote != old_vote, 1000); // VOTE_NOT_CHANGED
            if (old_vote) *&mut proposal.approval_votes = *&proposal.approval_votes - 1
            else *&mut proposal.cancellation_votes = *&proposal.cancellation_votes - 1;
        };

        // cast new vote
        vec_map::insert(&mut proposal.votes, sender, vote);
        if (vote) *&mut proposal.approval_votes = *&proposal.approval_votes + 1
        else *&mut proposal.cancellation_votes = *&proposal.cancellation_votes + 1;
    }

    public fun execute_participant_changes(multisig: &mut Multisig, proposal_id: u64) {
        // get multisig ID and proposal from ID
        let proposals = &mut multisig.proposals;
        assert!(proposal_id <= vector::length(proposals), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposal = vector::borrow_mut(proposals, proposal_id);

        // make sure proposal has enough approval votes but is not cancelled
        assert!(proposal.approval_votes >= multisig.approval_threshold, 1000); // NOT_ENOUGH_APPROVALS
        assert!(proposal.cancellation_votes < multisig.cancellation_threshold, 1000); // PROPOSAL_ALREADY_CANCELED

        // make sure there are changes to be made
        assert!(!vector::is_empty(&proposal.remove_participants) || !vector::is_empty(&proposal.add_participants), 1000); // NO_PENDING_PARTICIPANT_CHANGES

        // execute participant removals
        while (!vector::is_empty(&proposal.remove_participants)) {
            let participant = vector::pop_back(&mut proposal.remove_participants);
            vec_map::remove(&mut multisig.participants, &participant);
        };

        // execute participant additions
        while (!vector::is_empty(&proposal.add_participants)) {
            let participant = vector::pop_back(&mut proposal.add_participants);
            vec_map::insert(&mut multisig.participants, participant, true);
        };
    }

    public fun withdraw_to<AssetType>(
        multisig: &mut Multisig,
        record1: &mut PendingWithdrawalTransferRecord<AssetType>,
        record2: &mut DepositRecord<AssetType>,
        proposal_id: u64,
        ctx: &mut TxContext
    ) {
        // get proposal from ID
        let proposals = &mut multisig.proposals;
        assert!(proposal_id <= vector::length(proposals), 1000); // MULTISIG_DOES_NOT_EXIST
        let proposal = vector::borrow_mut(proposals, proposal_id);

        // make sure proposal has enough approval votes but is not cancelled
        assert!(proposal.approval_votes >= multisig.approval_threshold, 1000); // NOT_ENOUGH_APPROVALS
        assert!(proposal.cancellation_votes < multisig.cancellation_threshold, 1000); // PROPOSAL_ALREADY_CANCELED

        // get withdrawal amount and remove pending withdrawal from map
        let multisig_id = object::id(multisig);
        let combined_id = ProposalID { multisig_id: *multisig_id, proposal_id };
        assert!(vec_map::contains(&record1.record, &combined_id), 1000); // ASSET_NOT_IN_PROPOSAL
        let (_, transfer_data) = vec_map::remove(&mut record1.record, &combined_id);

        // withdraw coins (if less than total, withdraw and reinsert)
        let record2_inner = &mut record2.record;
        assert!(vec_map::contains(record2_inner, multisig_id), 1000); // INSUFFICIENT_FUNDS
        let (_, multisig_coin) = vec_map::remove(record2_inner, multisig_id);
        let funds_available = coin::value(&multisig_coin);
        assert!(funds_available >= transfer_data.amount, 1000); // INSUFFICIENT_FUNDS

        if (funds_available > transfer_data.amount) {
            let coin_out = coin::take(coin::balance_mut(&mut multisig_coin), transfer_data.amount, ctx);
            vec_map::insert(record2_inner, *multisig_id, multisig_coin);
            coin::transfer(coin_out, transfer_data.recipient)
        } else {
            coin::transfer(multisig_coin, transfer_data.recipient)
        }
    }

    public fun withdraw<AssetType>(
        multisig: &Multisig,
        record1: &mut PendingAuthedWithdrawalRecord<AssetType>,
        record2: &mut DepositRecord<AssetType>,
        auth_token: &AuthToken,
        ctx: &mut TxContext
    ): Coin<AssetType> {
        // get multisig ID and proposal from ID
        let multisig_id = object::id(multisig);
        assert!(*multisig_id == auth_token.multisig_id, 1000); // AUTH_TOKEN_MULTISIG_MISMATCH
        let proposal = vector::borrow(&multisig.proposals, auth_token.proposal_id);

        // make sure proposal has enough votes
        assert!(proposal.approval_votes >= multisig.approval_threshold, 1000); // PROPOSAL_NOT_APPROVED
        assert!(proposal.cancellation_votes < multisig.cancellation_threshold, 1000); // PROPOSAL_ALREADY_CANCELED

        // get withdrawal amount and remove pending withdrawal from map
        let combined_id = ProposalID { multisig_id: auth_token.multisig_id, proposal_id: auth_token.proposal_id };
        assert!(vec_map::contains(&record1.record, &combined_id), 1000); // ASSET_NOT_IN_PROPOSAL
        let (_, withdrawal_amount) = vec_map::remove(&mut record1.record, &combined_id);

        // withdraw coins (if less than total, withdraw and reinsert)
        let record2_inner = &mut record2.record;
        assert!(vec_map::contains(record2_inner, &auth_token.multisig_id), 1000); // INSUFFICIENT_FUNDS
        let (_, multisig_coin) = vec_map::remove(record2_inner, &auth_token.multisig_id);
        let funds_available = coin::value(&multisig_coin);
        assert!(funds_available >= withdrawal_amount, 1000); // INSUFFICIENT_FUNDS

        if (funds_available > withdrawal_amount) {
            let coin_out = coin::take(coin::balance_mut(&mut multisig_coin), withdrawal_amount, ctx);
            vec_map::insert(record2_inner, auth_token.multisig_id, multisig_coin);
            coin_out
        } else {
            multisig_coin
        }
    }

    public fun withdraw_objects<T: store>(
        multisig: &Multisig,
        record1: &mut PendingAuthedObjectWithdrawalRecord<T>,
        record2: &mut ObjectDepositRecord<T>,
        auth_token: &AuthToken
    ): vector<T> {
        // get multisig ID and proposal from ID
        let multisig_id = object::id(multisig);
        assert!(*multisig_id == auth_token.multisig_id, 1000); // AUTH_TOKEN_MULTISIG_MISMATCH
        let proposal = vector::borrow(&multisig.proposals, auth_token.proposal_id);

        // make sure proposal has enough votes
        assert!(proposal.approval_votes >= multisig.approval_threshold, 1000); // PROPOSAL_NOT_APPROVED
        assert!(proposal.cancellation_votes < multisig.cancellation_threshold, 1000); // PROPOSAL_ALREADY_CANCELED

        // get object IDs to be withdrawn and remove pending withdrawal from map
        let combined_id = ProposalID { multisig_id: auth_token.multisig_id, proposal_id: auth_token.proposal_id };
        assert!(vec_map::contains(&record1.record, &combined_id), 1000); // OBJECT_TYPE_NOT_IN_PROPOSAL
        let (_, object_ids) = vec_map::remove(&mut record1.record, &combined_id);

        // withdraw objects
        assert!(vec_map::contains(&record2.record, &auth_token.multisig_id), 1000); // RECORD_NOT_FOUND
        let objects = vec_map::get_mut(&mut record2.record, &auth_token.multisig_id);
        let output = vector::empty<T>();

        while (!vector::is_empty(&object_ids)) {
            let (_, object) = vec_map::remove(&mut objects.objects, &vector::pop_back(&mut object_ids));
            vector::push_back(&mut output, object);
        };

        output
    }
}
