#!/usr/bin/env node

const fs = require('fs').promises;
const path = require('path');

const BROADCAST_DIR = 'broadcast';
const OUTPUT_FILE = 'contracts.json';

// Contract name mapping: contractName -> camelCase key
const CONTRACT_NAME_MAPPING = {
  'V3Utils': 'v3Utils',
  'V3Automation': 'v3Automation',
  'Nfpm': 'nfpmLib',
  'StructHash': 'structHash'
};

/**
 * Parse library string from broadcast file
 * Format: "src/File.sol:ContractName:0xAddress"
 * @param {string} libString - Library string from broadcast file
 * @returns {{contractName: string, address: string}}
 */
function parseLibrary(libString) {
  const parts = libString.split(':');
  if (parts.length !== 3) {
    throw new Error(`Invalid library format: ${libString}`);
  }

  const contractName = parts[1]; // e.g., "Nfpm"
  const address = parts[2].toLowerCase(); // Normalize to lowercase

  return { contractName, address };
}

/**
 * Map contract name to camelCase key
 * @param {string} contractName - Contract name from broadcast
 * @returns {string} - Mapped camelCase key
 */
function mapContractName(contractName) {
  return CONTRACT_NAME_MAPPING[contractName] || contractName;
}

/**
 * Validate Ethereum address
 * @param {string} address - Address to validate
 * @returns {boolean}
 */
function validateAddress(address) {
  if (!address || typeof address !== 'string') {
    return false;
  }
  // Check if valid Ethereum address (0x + 40 hex chars)
  return /^0x[a-fA-F0-9]{40}$/.test(address);
}

/**
 * Discover all chain IDs from broadcast directory
 * @returns {Promise<Set<string>>} - Set of unique chain IDs
 */
async function discoverChainIds() {
  const chainIds = new Set();

  try {
    const broadcastPath = path.join(__dirname, BROADCAST_DIR);
    const scriptDirs = await fs.readdir(broadcastPath, { withFileTypes: true });

    // Iterate through script directories (e.g., V3Utils.s.sol/)
    for (const scriptDir of scriptDirs) {
      if (!scriptDir.isDirectory()) continue;

      const scriptPath = path.join(broadcastPath, scriptDir.name);
      try {
        const chainDirs = await fs.readdir(scriptPath, { withFileTypes: true });

        // Collect chain IDs (numeric directory names)
        for (const chainDir of chainDirs) {
          if (chainDir.isDirectory() && /^\d+$/.test(chainDir.name)) {
            chainIds.add(chainDir.name);
          }
        }
      } catch (error) {
        // Skip if can't read directory
        continue;
      }
    }
  } catch (error) {
    console.warn(`Warning: Could not read broadcast directory: ${error.message}`);
  }

  return chainIds;
}

/**
 * Extract contracts from a single broadcast file
 * @param {string} filePath - Path to broadcast JSON file
 * @returns {Promise<Object|null>} - Object mapping contract keys to addresses
 */
async function extractFromBroadcastFile(filePath) {
  try {
    const content = await fs.readFile(filePath, 'utf-8');
    const data = JSON.parse(content);
    const contracts = {};

    // Extract main contract from transactions[0]
    if (data.transactions && Array.isArray(data.transactions) && data.transactions.length > 0) {
      const tx = data.transactions[0];
      if (tx.contractName && tx.contractAddress) {
        const address = tx.contractAddress.toLowerCase();
        if (validateAddress(address)) {
          const key = mapContractName(tx.contractName);
          contracts[key] = address;
        }
      }
    }

    // Extract libraries
    if (data.libraries && Array.isArray(data.libraries)) {
      for (const libString of data.libraries) {
        try {
          const { contractName, address } = parseLibrary(libString);
          if (validateAddress(address)) {
            const key = mapContractName(contractName);
            contracts[key] = address;
          }
        } catch (error) {
          console.warn(`Warning: Could not parse library: ${libString}`);
        }
      }
    }

    return contracts;
  } catch (error) {
    if (error.code === 'ENOENT') {
      // File not found, skip silently
      return null;
    }
    console.warn(`Warning: Failed to read ${filePath}: ${error.message}`);
    return null;
  }
}

/**
 * Extract all contracts for a specific chain ID
 * @param {string} chainId - Chain ID to extract contracts for
 * @returns {Promise<Object>} - Object mapping contract keys to addresses
 */
async function extractContractsForChain(chainId) {
  const contracts = {};
  const broadcastPath = path.join(__dirname, BROADCAST_DIR);

  try {
    const scriptDirs = await fs.readdir(broadcastPath, { withFileTypes: true });

    for (const scriptDir of scriptDirs) {
      if (!scriptDir.isDirectory()) continue;

      const runLatestPath = path.join(
        broadcastPath,
        scriptDir.name,
        chainId,
        'run-latest.json'
      );

      const extracted = await extractFromBroadcastFile(runLatestPath);
      if (extracted) {
        Object.assign(contracts, extracted);
      }
    }
  } catch (error) {
    console.warn(`Warning: Could not process chain ${chainId}: ${error.message}`);
  }

  return contracts;
}

/**
 * Main function
 */
async function main() {
  try {
    console.log('Extracting contract addresses from broadcast files...\n');

    // 1. Discover all chain IDs
    const chainIds = await discoverChainIds();
    console.log(`Found ${chainIds.size} chain(s): ${Array.from(chainIds).join(', ')}`);

    if (chainIds.size === 0) {
      console.warn('No chain IDs found in broadcast directory');
      return;
    }

    // 2. Extract contracts for each chain
    const allContracts = {};
    for (const chainId of chainIds) {
      const contracts = await extractContractsForChain(chainId);
      if (Object.keys(contracts).length > 0) {
        allContracts[chainId] = contracts;
        console.log(`  Chain ${chainId}: Found ${Object.keys(contracts).length} contract(s)`);
      }
    }

    // 3. Read existing contracts.json
    let existingData = {};
    const outputPath = path.join(__dirname, OUTPUT_FILE);
    try {
      const content = await fs.readFile(outputPath, 'utf-8');
      existingData = JSON.parse(content);
    } catch (error) {
      if (error.code !== 'ENOENT') {
        throw error;
      }
      // File doesn't exist, start fresh
      console.log('  contracts.json does not exist, creating new file');
    }

    // 4. Merge: update broadcast chains, preserve non-broadcast chains
    const mergedData = { ...existingData };

    // Update chains from broadcast
    for (const chainId of Object.keys(allContracts)) {
      mergedData[chainId] = allContracts[chainId];
    }

    // Sort chain IDs numerically for deterministic output
    const sortedData = {};
    const chainIdsSorted = Object.keys(mergedData).sort((a, b) => parseInt(a) - parseInt(b));
    for (const chainId of chainIdsSorted) {
      // Sort contract keys alphabetically within each chain
      const contracts = mergedData[chainId];
      const sortedContracts = {};
      const contractKeys = Object.keys(contracts).sort();
      for (const key of contractKeys) {
        sortedContracts[key] = contracts[key];
      }
      sortedData[chainId] = sortedContracts;
    }

    // 5. Write to file
    await fs.writeFile(
      outputPath,
      JSON.stringify(sortedData, null, 2) + '\n',
      'utf-8'
    );

    console.log(`\n✓ Successfully updated ${OUTPUT_FILE}`);

    // Summary
    const totalContracts = Object.values(allContracts).reduce(
      (sum, contracts) => sum + Object.keys(contracts).length,
      0
    );
    console.log(`  Updated ${chainIds.size} chain(s) with ${totalContracts} total contract(s)`);

    // Show preserved chains if any
    const preservedChains = Object.keys(existingData).filter(
      chainId => !chainIds.has(chainId)
    );
    if (preservedChains.length > 0) {
      console.log(`  Preserved ${preservedChains.length} chain(s) not in broadcast: ${preservedChains.join(', ')}`);
    }

  } catch (error) {
    console.error('Error:', error.message);
    process.exit(1);
  }
}

main();
