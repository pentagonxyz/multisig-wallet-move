# Multiture: A Dynamic Multisignature Wallet on Aptos

Multiture is a dynamic (i.e., supports modifying participants) multisignature wallet (similar to Gnosis Safe) built on Aptos for storing [`Coin`s](https://github.com/aptos-labs/aptos-core/blob/main/aptos-move/framework/aptos-framework/sources/Coin.move) and [`Token`s](https://github.com/aptos-labs/aptos-core/blob/main/aptos-move/framework/aptos-framework/sources/Token.move).

## Public Functions

* `public fun initialize(root: &signer)`
* `public fun enable_deposits<AssetType>(root: &signer)`
* `public fun create_multisig(participants: vector<address>, approval_threshold: u64, cancellation_threshold: u64): u64 acquires MultisigBank`
* `public fun deposit<AssetType>(multisig_id: u64, coin: Coin<AssetType>) acquires DepositRecord`
* `public fun create_proposal(account: &signer, multisig_id: u64, add_participants: vector<address>, remove_participants: vector<address>, approve_messages: vector<vector<u8>>, withdraw_tokens: vector<PendingTokenWithdrawal>) acquires MultisigBank`
* `public fun request_authed_withdrawal<AssetType>(account: &signer, multisig_id: u64, proposal_id: u64, amount: u64) acquires MultisigBank, PendingAuthedWithdrawalRecord`
* `public fun request_withdrawal_transfer<AssetType>(account: &signer, multisig_id: u64, proposal_id: u64, recipient: address, amount: u64) acquires MultisigBank, PendingWithdrawalTransferRecord`
* `public fun post_proposal(account: &signer, multisig_id: u64, proposal_id: u64): AuthToken acquires MultisigBank`
* `public fun cast_vote(account: &signer, multisig_id: u64, proposal_id: u64, vote: bool) acquires MultisigBank`
* `public fun execute_participant_changes(multisig_id: u64, proposal_id: u64) acquires MultisigBank`
* `public fun execute_token_withdrawals(dummy: &signer, multisig_id: u64, proposal_id: u64) acquires MultisigBank`
* `public fun withdraw_to<AssetType>(multisig_id: u64, proposal_id: u64) acquires MultisigBank, PendingWithdrawalTransferRecord, DepositRecord`
* `public fun withdraw<AssetType>(auth_token: &AuthToken): Coin<AssetType> acquires MultisigBank, PendingAuthedWithdrawalRecord, DepositRecord`
