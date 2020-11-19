const Reports = artifacts.require("./Reports.sol");
const PT = artifacts.require("./PersonalToken.sol");

module.exports = async function (deployer) {
    await deployer.deploy(Reports)
    const reports = await Reports.deployed()
    console.log("Reports address", reports.address)

    await deployer.deploy(PT, web3.utils.toWei("100"))
    const pt = await PT.deployed()
    console.log("PT address", pt.address)
};