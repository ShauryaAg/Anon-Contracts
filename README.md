# Anon-Contracts

> Frontend Repo @ https://github.com/ShauryaAg/Anon-Reporter.git

This repo contains the smart contracts used for Anon-Reporter.

## Structure

```
│   .gitignore
│   package-lock.json
│   package.json
│   README.md
│   truffle-config.js
│
├───build
│   └───contracts
|            └───.... 
│           
├───contracts
│   │   Migrations.sol
│   │   PersonalToken.sol
│   │   Reports.sol
│   │   Types.sol
│   │
│   ├───compound
│   │       CarefulMath.sol
│   │       Exponential.sol
│   │       
│   └───interfaces
│           IERC1620.sol
│
├───migrations
│       1_initial_migration.js
│       2_deploy_migration.js
```

```contracts/``` folder contains all the smart contracts for running Anon.
```migrations/``` folders contains the code to deploy the smart contracts on any network.

```truffle-config.js``` files contains the specification for network and solidity compiler.
In order to deploy on Matic network, create a ```.secret``` in the root directory file with your wallets mnemonics.

### Usage

To compile and deploy on any network: ```truffle migrate --network <network-name>```
At the moment there are two network specified ```development``` and ```matic```

```Development``` network is used for development purposes on localhost using ```ganache-cli```