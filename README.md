# v3utils

This repository contains the smart contracts for v3Utils and v3Automation.

It uses Foundry as development toolchain.


## Setup

Install foundry 

https://book.getfoundry.sh/getting-started/installation

Install dependencies

```sh
forge install
```


## Tests

Most tests use a forked state of Arbitrum One network. You can run all tests with: 

NOTE: 
Prepare .env file with sample values from sample.env before you run test.

```sh
forge test
```

Run tests with gas report
```sh
forge test --gas-report
```

# Remember to check smart wallet address
Note: If you need to deploy StructHash contract, you need to update its latest address in `foundry.toml`
# Deploy
```
source .env
forge script script/V3Utils.s.sol:MyScript --legacy --rpc-url $RPC_URL --broadcast
```
using `--with-gas-price` flag to specify gas price:
```
forge script script/V3Utils.s.sol:MyScript --legacy --rpc-url $RPC_URL --broadcast --with-gas-price $GAS_PRICE
```
or with Makefile:
```
make deploy-v3utils
```
# Verify Contract

Run script below to get verify contract script
```
make verify-v3utils
```
# Notes
`StructHash`, `Nfpm` and `CommonLib` are CREATE2-deployed libraries, linked by address rather than
compiled into the contracts that use them. `CommonLib` exists because `V3Utils` sits close to the
EIP-170 24576-byte limit: moving the heavy shared helpers into an external library is what keeps it
under. Deploy them before the contracts that link them (`make deploy-everything` does this in order).

If any of them is updated or deployed to a new chain, update its address in `foundry.toml`:
```toml
libraries = [
    'src/StructHash.sol:StructHash:<new_address>',
    'src/Nfpm.sol:Nfpm:<new_address>',
    'src/CommonLib.sol:CommonLib:<new_address>'
]
```
and keep `COMMON_LIB_ADDRESS` / `NFPM_LIB_ADDRESS` / `STRUCT_HASH_ADDRESS` in `.env` in step, since
the verify scripts read the addresses from there.

These three files are excluded from `forge fmt` on purpose: their deployed address is derived from
`keccak256(creationCode)`, and the appended metadata hash covers the source bytes, so reformatting
them changes their address.
