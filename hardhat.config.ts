import type { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

const BATCH = process.env.BATCH ?? "batch_01";

const config: HardhatUserConfig = {
  paths: {
    sources: BATCH === "_temp_single"
      ? `./contracts/_compile_all`
      : `./contracts/generated/${BATCH}`,
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
