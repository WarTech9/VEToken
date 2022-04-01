import * as dotenv from "dotenv";

import { HardhatUserConfig, task } from "hardhat/config";
import "@nomiclabs/hardhat-etherscan";
import "@nomiclabs/hardhat-waffle";
import "@typechain/hardhat";
import "hardhat-gas-reporter";
import "solidity-coverage";

dotenv.config();

const privateKey = process.env.PRIVATE_KEY || "";
const privateKey2 = process.env.PRIVATE_KEY2 || "";

// This is a sample Hardhat task. To learn how to create your own go to
// https://hardhat.org/guides/create-task.html
task("accounts", "Prints the list of accounts", async (taskArgs, hre) => {
  const accounts = await hre.ethers.getSigners();

  for (const account of accounts) {
    console.log(account.address);
  }
});

// You need to export an object to set up your config
// Go to https://hardhat.org/config/ to learn more

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.6.11",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1000000,
          },
        },
      },
      {
        version: "0.8.9",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1000000,
          },
        },
      },
    ],
  },
  networks: {
    localhost: {
      url: "http://localhost:8545",
      accounts: [
        "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
        "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
        "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
      ],
      chainId: 31337,
      gas: 8500000,
      gasPrice: 1000000000000,
      // blockGasLimit: 124500000,
    },
    ropsten: {
      url: process.env.ROPSTEN_URL || "",
      accounts:
        process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },
    avalanchefuji: {
      // Infura
      // url: `https://polygon-mumbai.infura.io/v3/${infuraId}`,
      url: `https://api.avax-test.network/ext/bc/C/rpc`,
      accounts: [privateKey, privateKey2],
      gas: 8000000,
      chainId: 43113,
      gasPrice: 225000000000, // 225 Gwei
      timeout: 120000,
    },
    avalanchesubnet: {
      // Infura
      // url: `https://polygon-mumbai.infura.io/v3/${infuraId}`,
      url: `https://api.avax-test.network/ext/bc/defimonstest/rpc`,
      accounts: [privateKey, privateKey2],
      gas: 8000000,
      chainId: 43113,
      gasPrice: 225000000000, // 225 Gwei
      timeout: 120000,
    },
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS !== undefined,
    currency: "USD",
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY,
  },
};

export default config;
