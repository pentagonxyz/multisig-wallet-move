address 0x2 {

module Map {
    native struct T<K, V> has copy, drop, store;

    native public fun empty<K, V>(): T<K, V>;

    native public fun get<K, V>(m: &T<K, V>, k: &K): &V;
    native public fun get_mut<K, V>(m: &mut T<K, V>, k: &K): &mut V;

    native public fun contains_key<K, V>(m: &T<K, V>, k: &K): bool;
    // throws on duplicate as I don't feel like mocking up Option
    native public fun insert<K, V>(m: &T<K, V>, k: K, v: V);
    // throws on miss as I don't feel like mocking up Option
    native public fun remove<K, V>(m: &T<K, V>, k: &K): V;
}

}

address 0x2 {

module Token {
    struct Coin<AssetType: copy + drop> has store {
        type: AssetType,
        value: u64,
    }

    // control the minting/creation in the defining module of `ATy`
    public fun create<ATy: copy + drop>(type: ATy, value: u64): Coin<ATy> {
        Coin { type, value }
    }

    public fun value<ATy: copy + drop>(coin: &Coin<ATy>): u64 {
        coin.value
    }

    public fun split<ATy: copy + drop>(coin: Coin<ATy>, amount: u64): (Coin<ATy>, Coin<ATy>) {
        let other = withdraw(&mut coin, amount);
        (coin, other)
    }

    public fun withdraw<ATy: copy + drop>(coin: &mut Coin<ATy>, amount: u64): Coin<ATy> {
        assert!(coin.value >= amount, 10);
        coin.value = coin.value - amount;
        Coin { type: *&coin.type, value: amount }
    }

    public fun join<ATy: copy + drop>(xus: Coin<ATy>, coin2: Coin<ATy>): Coin<ATy> {
        deposit(&mut xus, coin2);
        xus
    }

    public fun deposit<ATy: copy + drop>(coin: &mut Coin<ATy>, check: Coin<ATy>) {
        let Coin { value, type } = check;
        assert!(&coin.type == &type, 42);
        coin.value = coin.value + value;
    }

    public fun destroy_zero<ATy: copy + drop>(coin: Coin<ATy>) {
        let Coin { value, type: _ } = coin;
        assert!(value == 0, 11)
    }
}

}

address 0x5 {

module MultisigWallet {
    use Std::Signer;
    use Std::Vector;

    use 0x2::Map;
    use 0x2::Token;

    struct MultisigBank has key {
        multisigs: vector<Multisig>
    }

    struct Multisig has store {
        participants: Map::T<address, bool>,
        approval_threshold: u64,
        cancellation_threshold: u64,
        proposals: vector<Proposal>
    }

    struct Proposal has store {
        creator: address,
        posted: bool,
        votes: Map::T<address, bool>,
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

    struct DepositRecord<AssetType: copy + drop> has key {
        record: Map::T<u64, Token::Coin<AssetType>>
    }

    struct PendingWithdrawalRecord<phantom AssetType: copy + drop> has key {
        record: Map::T<ProposalID, u64>
    }

    struct ProposalID has store {
        multisig_id: u64,
        proposal_id: u64
    }

    public fun create_multisig(account: &signer, participants: vector<address>, approval_threshold: u64, cancellation_threshold: u64): u64 acquires MultisigBank {
        // create multisig resource
        let multisig = Multisig { participants: Map::empty(), approval_threshold, cancellation_threshold, proposals: Vector::empty() };
        while (!Vector::is_empty(&participants)) {
            let participant = Vector::pop_back(&mut participants);
            Map::insert(&mut multisig.participants, participant, true);
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

    public fun enable_deposits<AssetType: copy + drop + store>(account: &signer) {
        // validate deposits are not yet enabled
        let sender = Signer::address_of(account);
        assert!(!exists<DepositRecord<AssetType>>(sender), 1000); // DEPOSITS_ALREADY_ENABLED

        // add deposit record and withdrawal request record
        move_to(account, DepositRecord<AssetType> { record: Map::empty() });
        move_to(account, PendingWithdrawalRecord<AssetType> { record: Map::empty() });
    }

    public fun deposit<AssetType: copy + drop + store>(multisig_initiator: address, multisig_id: u64, coin: Token::Coin<AssetType>) acquires DepositRecord {
        // validate deposits are enabled for this asset
        assert!(exists<DepositRecord<AssetType>>(multisig_initiator), 1000); // ASSET_NOT_SUPPORTED

        // insert coin (if coin already exists, first remove old coin and combine with new coin before reinserting combined coin)
        let record = &mut borrow_global_mut<DepositRecord<AssetType>>(multisig_initiator).record;
        if (Map::contains_key(record, &multisig_id)) {
            let old_coin = Map::remove(record, &multisig_id);
            Token::deposit(&mut coin, old_coin);
        };
        Map::insert(record, multisig_id, coin);
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
            votes: Map::empty(),
            approval_votes: 0,
            cancellation_votes: 0,
            add_participants,
            remove_participants,
            approve_messages
        });
    }

    public fun request_withdrawal<AssetType: copy + drop>(account: &signer, multisig_initiator: address, multisig_id: u64, proposal_id: u64, amount: u64)
        acquires MultisigBank, PendingWithdrawalRecord
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
        assert(exists<PendingWithdrawalRecord<AssetType>>(multisig_initiator), 1000); // ASSET_NOT_SUPPORTED
        let record = &mut borrow_global_mut<PendingWithdrawalRecord<AssetType>>(multisig_initiator).record;
        let combined_id = ProposalID { multisig_id, proposal_id };
        if (Map::contains_key(record, &combined_id)) {
            let old_amount = Map::remove(record, &combined_id);
            amount = amount + old_amount;
        };
        Map::insert(record, combined_id, amount)
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
        assert!(Map::contains_key(&multisig.participants, &sender) && *Map::get(&multisig.participants, &sender), 1000); // UNAUTHORIZED_PARTICIPANT

        // remove old vote if necessary
        if (Map::contains_key(&proposal.votes, &sender)) {
            let old_vote = Map::remove(&mut proposal.votes, &sender);
            assert!(vote != old_vote, 1000); // VOTE_NOT_CHANGED
            if (old_vote) *&mut proposal.approval_votes = *&proposal.approval_votes - 1
            else *&mut proposal.cancellation_votes = *&proposal.cancellation_votes - 1;
        };

        // cast new vote
        Map::insert(&mut proposal.votes, sender, vote);
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
            Map::remove(&mut multisig.participants, &participant);
        };

        // execute additions
        while (!Vector::is_empty(&proposal.add_participants)) {
            let participant = Vector::pop_back(&mut proposal.add_participants);
            Map::insert(&mut multisig.participants, participant, true);
        };
    }

    public fun withdraw<AssetType: copy + drop + store>(auth_token: &AuthToken): Token::Coin<AssetType>
        acquires MultisigBank, PendingWithdrawalRecord, DepositRecord
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
        assert!(exists<PendingWithdrawalRecord<AssetType>>(auth_token.multisig_initiator), 1000); // ASSET_NOT_SUPPORTED
        let record = &mut borrow_global_mut<PendingWithdrawalRecord<AssetType>>(auth_token.multisig_initiator).record;
        let combined_id = ProposalID { multisig_id: auth_token.multisig_id, proposal_id: auth_token.proposal_id };
        assert!(Map::contains_key(record, &combined_id), 1000); // ASSET_NOT_IN_PROPOSAL
        let withdrawal_amount = Map::remove(record, &combined_id);

        // withdraw tokens (if less than total, withdraw and reinsert)
        let record = &mut borrow_global_mut<DepositRecord<AssetType>>(auth_token.multisig_initiator).record;
        assert!(Map::contains_key(record, &auth_token.multisig_id), 1000); // INSUFFICIENT_FUNDS
        let multisig_coin = Map::remove(record, &auth_token.multisig_id);
        let funds_available = Token::value(&multisig_coin);
        assert!(funds_available >= withdrawal_amount, 1000); // INSUFFICIENT_FUNDS

        if (funds_available > withdrawal_amount) {
            let coin_out = Token::withdraw(&mut multisig_coin, withdrawal_amount);
            Map::insert(record, auth_token.multisig_id, multisig_coin);
            coin_out
        } else {
            multisig_coin
        }
    }
}

}
