const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Chrysalis (unit) - placeholder tests", function() {
  it("deploys sender and receiver", async function() {
    const [deployer] = await ethers.getSigners();
    const Sender = await ethers.getContractFactory("ChrysalisSender");
    const Receiver = await ethers.getContractFactory("ChrysalisReceiver");
    const sender = await Sender.deploy();
    await sender.deployed();
    const receiver = await Receiver.deploy();
    await receiver.deployed();
    expect(sender.address).to.properAddress;
    expect(receiver.address).to.properAddress;
  });
});
