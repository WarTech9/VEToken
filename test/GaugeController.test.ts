import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { expect } from "chai";
import { BigNumber } from "ethers";
import { ethers } from "hardhat";
import moment from "moment";
import { Token, VEToken } from "../typechain";
import { GaugeController } from "../typechain/GaugeController";

describe("GaugeController", function () {
  let controller: GaugeController;
  let token: Token;
  let veToken: VEToken;
  let mockVe: Token;
  let account0: SignerWithAddress;
  let account1: SignerWithAddress;
  let account2: SignerWithAddress;

  this.beforeEach(async () => {
    const signers = await ethers.getSigners();
    [account0, account1, account2] = [signers[0], signers[1], signers[2]];
    const GaugeController = await ethers.getContractFactory("GaugeController");
    controller = await GaugeController.deploy();
    await controller.deployed();

    const Token = await ethers.getContractFactory("Token");
    token = await Token.deploy(
      "Token",
      "TOK",
      ethers.utils.parseEther("1000000")
    );
    await token.deployed();

    const VE = await ethers.getContractFactory("VEToken");
    veToken = await VE.deploy(token.address, "VE Token", "VET", "1.0");
    await veToken.deployed();

    const MockVE = await ethers.getContractFactory("Token");
    mockVe = await MockVE.deploy(
      "Mock VE",
      "MOCK",
      ethers.utils.parseEther("1000000")
    );
    await mockVe.deployed();

    await controller.setVeToken(mockVe.address);
    await controller.setRewardsToken(token.address);
  });

  it("Can create gauges", async function () {
    await controller.createGenesisEpoch(moment().add(1, "minute").unix());
    const tx = await controller.createGauge();
    const rv = await tx.wait();
    console.log("rv = ", rv);
    const gauges = await controller.allGauges();
    const numberOfGauges = await controller.numberOfGauges();
    expect(numberOfGauges).to.equal(1);
    expect(gauges.length).to.equal(1);
    console.log("gauges = ", gauges);
  });

  it("Can vote on gauges", async () => {
    await controller.createGenesisEpoch(moment().add(1, "minute").unix());

    // create two gauges.
    await controller.createGauge();
    await controller.createGauge();

    const gauges = await controller.allGauges();

    // voting without voting power should revert
    await expect(controller.connect(account1).vote(gauges[0])).to.be.reverted;

    // transfer voting power with mock token. Actual VE non-transferrable
    await mockVe.transfer(account1.address, ethers.utils.parseEther("5000"));
    await mockVe.transfer(account2.address, ethers.utils.parseEther("1000"));

    // check total votes before any voting is done
    let totalVotes = await controller.currentEpochTotalVotes();
    expect(totalVotes.eq(0)).to.equal(true);

    // voting should succeed now
    await controller.connect(account1).vote(gauges[0]);
    await controller.connect(account2).vote(gauges[1]);
    totalVotes = await controller.currentEpochTotalVotes();

    const balance1 = await mockVe.balanceOf(account1.address);
    const balance2 = await mockVe.balanceOf(account2.address);

    // total votes cast must equal the sum of account balances.
    expect(totalVotes.eq(balance1.add(balance2))).to.equal(true);
  });

  it("Can distribute rewards to gauges", async () => {
    await controller.createGenesisEpoch(moment().add(1, "minute").unix());
  });

  it("Moving from epoch to next works", async () => {
    await controller.createGenesisEpoch(moment().add(1, "minute").unix());
  });
});
