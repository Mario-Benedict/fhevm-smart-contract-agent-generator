import type { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

const targetFolder = process.env.BATCH ? `./contracts/${process.env.BATCH}` : "./contracts";

const config: HardhatUserConfig = {
  paths: {
    sources: targetFolder,
  },
  solidity: {
    version: "0.8.24",
    settings: {
      viaIR: true,
      evmVersion: "cancun",
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
};

export default config;
