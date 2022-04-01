// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
import { ethers } from "hardhat";

async function main() {
  // Hardhat always runs the compile task when running scripts with its command
  // line interface.
  //
  // If this script is run directly using `node` you may want to call compile
  // manually to make sure everything is compiled
  // await hre.run('compile');

  const name = "Voting Escrowed MON";
  const symbol = "veMON";
  const version = "1.0";
  const totalSupply = ethers.utils.parseEther("1000000000");
  // We get the contract to deploy
  const Token = await ethers.getContractFactory("Token");
  const token = await Token.deploy("token", "TOKE", totalSupply);

  const VEToken = await ethers.getContractFactory("VEToken");
  const veMon = await VEToken.deploy(token.address, name, symbol, version);
  await veMon.deployed();
  console.log("veMON depoloyed to address => ", veMon.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
