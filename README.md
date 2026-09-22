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

If any of them is updated or deployed to a new chain, update its address in `foundry.toml` - in
`[profile.v3utilslinker]` (what `V3Utils` links) and/or `[profile.linker]` (what `V3Automation`
links):
```toml
libraries = [
    'src/StructHash.sol:StructHash:<new_address>',
    'src/Nfpm.sol:Nfpm:<new_address>',
    'src/CommonLib.sol:CommonLib:<new_address>'
]
```
That list is the only place the addresses live. The deploy links against it, and `make verify-*`
reads it back out to build its `--libraries` flags, so the two cannot drift apart.

`script/check-libs.sh <profile>` preflights that list against the chain `RPC_URL` points at, and
runs automatically before every deploy and verify target. It compares the on-chain code at each
pinned address with the library as built here:

| | |
|---|---|
| `OK` | matches byte for byte |
| `WARN` | matches once the trailing CBOR metadata is stripped - same executable code, but deployed from a different source revision or compiler settings, so that deploy is not reproducible from HEAD |
| `FAIL` | different code, or nothing deployed at that address - blocks the deploy |

It builds the libraries under `[profile.default]`, because that is what `make deploy-nfpm`,
`deploy-commonlib` and `deploy-structhash` use. Building them under a linker profile would never
match: `libraries` is one of the compiler settings the metadata hash covers.

`Nfpm` and `StructHash` currently report `WARN` on every chain, and that is expected: they were
deployed before PR #60 added two lines to `remappings.txt`, and remappings are part of the settings
the metadata hash covers. Their executable code is identical to HEAD, so the warning is accepted
rather than cleared - clearing it would mean redeploying both and moving every chain's
`V3Utils`/`V3Automation` address. A `WARN` on a library that is *not* one of those two is worth
investigating.

These three files are excluded from `forge fmt` on purpose: their deployed address is derived from
`keccak256(creationCode)`, and the appended metadata hash covers the source bytes, so reformatting
them changes their address.
