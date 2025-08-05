import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import '@nomicfoundation/hardhat-verify'
import '@openzeppelin/hardhat-upgrades';
import "hardhat-deploy"


const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.28",
    settings: {
      viaIR: true,
      optimizer: {
        enabled: true,
        runs: 200
      }
    },
  },
  sourcify: {
    enabled: true
  }
};

export default config;
