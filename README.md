# Multiture: A Dynamic Multisignature Wallet on Sui and Aptos

Multiture is a dynamic (i.e., supports modifying participants) multisignature wallet (similar to Gnosis Safe) built on Sui and Aptos for storing coins, tokens, and generic objects.

## Public Functions

* `public entry fun initialize(root: &signer)`
* `public entry fun enable_deposits<AssetType>(root: &signer)`
* `public entry fun enable_object_deposits<T: store>(root: &signer)`
* `public fun create_multisig(participants: vector<address>, approval_threshold: u64, cancellation_threshold: u64): u64`
* `public fun deposit_object<T: store>(multisig_id: u64, obj: T)`
* `public fun deposit<AssetType>(multisig_id: u64, coin: Coin<AssetType>)`
* `public fun create_pending_token_withdrawal(tokenId: TokenId, value: u64, recipient: address): PendingTokenWithdrawal`
* `public fun create_proposal(account: &signer, multisig_id: u64, add_participants: vector<address>, remove_participants: vector<address>, approve_messages: vector<vector<u8>>, withdraw_tokens: vector<PendingTokenWithdrawal>)`
* `public entry fun request_authed_object_withdrawal<T: store>(account: &signer, multisig_id: u64, proposal_id: u64, ids: vector<u64>)`
* `public entry fun request_authed_withdrawal<AssetType>(account: &signer, multisig_id: u64, proposal_id: u64, amount: u64)`
* `public entry fun request_withdrawal_transfer<AssetType>(account: &signer, multisig_id: u64, proposal_id: u64, recipient: address, amount: u64)`
* `public fun post_proposal(account: &signer, multisig_id: u64, proposal_id: u64): AuthToken`
* `public entry fun cast_vote(account: &signer, multisig_id: u64, proposal_id: u64, vote: bool)`
* `public entry fun execute_participant_changes(multisig_id: u64, proposal_id: u64)`
* `public entry fun execute_token_withdrawals(dummy: &signer, multisig_id: u64, proposal_id: u64)`
* `public entry fun withdraw_to<AssetType>(multisig_id: u64, proposal_id: u64)`
* `public fun withdraw<AssetType>(auth_token: &AuthToken): Coin<AssetType>`
* `public fun withdraw_objects<T: store>(auth_token: &AuthToken): vector<T>`
