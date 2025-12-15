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
If StructHash is updated or deployed to a new chain, update its address in `foundry.toml`
```toml
libraries = [
    'src/StructHash.sol:StructHash:<new_address>'
]
```