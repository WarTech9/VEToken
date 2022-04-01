import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { expect } from "chai";
import { BigNumber } from "ethers";
import { ethers, network } from "hardhat";
import moment from "moment";
import { Token, VEToken } from "../typechain";

describe("VEToken", function () {
  const name = "Voting Escrowed MON";
  const symbol = "veMON";
  const version = "1.0";
  const totalSupply = ethers.utils.parseEther("1000000000");
  let account0: SignerWithAddress;
  let account1: SignerWithAddress;
  let ve: VEToken;
  let token: Token;

  beforeEach(async () => {
    const signers = await ethers.getSigners();
    [account0, account1] = [signers[0], signers[1]];
    const Token = await ethers.getContractFactory("Token");
    token = await Token.deploy("token", "TOKE", totalSupply);

    const VEToken = await ethers.getContractFactory("VEToken");
    ve = await VEToken.deploy(token.address, name, symbol, version);
    await ve.deployed();
  });

  // account0 deposits 1000 for 2 years
  // account1 deposits 1000 for 1 year
  // check that balance(account0) > balance(account1)
  it("has a higher balance if tokens deposited for longer time", async () => {
    const account0Amount = ethers.utils.parseEther("1000");
    const account1Amount = ethers.utils.parseEther("1000");
    const account0LockTime = moment().add(2, "year").unix();
    const account1LockTime = moment().add(1, "year").unix();

    await token.transfer(account1.address, account1Amount);

    await token.approve(ve.address, account0Amount);
    await token.connect(account1).approve(ve.address, account1Amount);

    await token.approve(ve.address, account0Amount);
    await token.connect(account1).approve(ve.address, account1Amount);

    // check that balance is initially zero
    let account0Balance = await ve["balanceOf(address)"](account0.address);
    expect(account0Balance).to.equal(BigNumber.from(0));

    // lock tokens for 2 years and 1 year respectively
    await ve.connect(account0).createLock(account0Amount, account0LockTime);
    await ve.connect(account1).createLock(account1Amount, account1LockTime);
    account0Balance = await ve["balanceOf(address)"](account0.address);
    const account1Balance = await ve["balanceOf(address)"](account1.address);

    expect(account0Balance).to.not.equal(BigNumber.from(0));

    // account0Balance > account1Balance for longer lock time
    expect(account0Balance.gt(account1Balance)).to.equal(true);
  });

  it("balance decays over time", async () => {
    // deposit and increase
    const amountToLock = ethers.utils.parseEther("1000");
    const lockTime = moment().add(3, "year").unix();
    await token.approve(ve.address, amountToLock);
    await ve.createLock(amountToLock, lockTime);
    const veMonBalance = await ve["balanceOf(address)"](account0.address);

    // mine some blocks to move time past start
    await network.provider.send("evm_increaseTime", [84600 * 365 * 1]);
    await network.provider.send("evm_mine");
    const newBalance = await ve["balanceOf(address)"](account0.address);
    expect(newBalance.lt(veMonBalance)).to.equal(true);
  });

  it("Can withdraw tokens after end time", async () => {
    // deposit tokens, check that balance are updated.
    // can not withdraw before unlock time.
    // can withdraw after unlock time.
    const amountToLock = ethers.utils.parseEther("1000");
    const lockTime = moment().add(1, "year").unix();
    const initialTokenBalance = await token.balanceOf(account0.address);
    await token.approve(ve.address, amountToLock);
    await ve.createLock(amountToLock, lockTime);

    const tokenBalanceAfterDeposit = await token.balanceOf(account0.address);
    expect(tokenBalanceAfterDeposit).to.be.lt(initialTokenBalance);

    // withdraw before 1 year unlock time should revert
    await expect(ve.withdraw()).to.be.reverted;

    const veMonBalance = await ve["balanceOf(address)"](account0.address);
    expect(veMonBalance).to.not.equal(BigNumber.from(0));

    // mine some blocks to move time past start
    await network.provider.send("evm_increaseTime", [84600 * 366]);
    await network.provider.send("evm_mine");

    // withdraw token should succeed now
    await ve.withdraw();
    const tokenBalanceAfterWithdraw = await token.balanceOf(account0.address);
    expect(tokenBalanceAfterWithdraw).to.equal(initialTokenBalance);
  });
});
