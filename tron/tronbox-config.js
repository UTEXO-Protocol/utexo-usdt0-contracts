require('dotenv').config();

const port = process.env.HOST_PORT || 9090;

module.exports = {
  networks: {
    mainnet: {      
      privateKey: process.env.PRIVATE_KEY_MAINNET,
      userFeePercentage: 100,
      feeLimit: 1000 * 1e6,
      fullHost: 'https://api.trongrid.io',
      network_id: '1'
    },
    shasta: {
      privateKey: process.env.PRIVATE_KEY_SHASTA,
      userFeePercentage: 50,
      feeLimit: 1000 * 1e6,
      fullHost: 'https://api.shasta.trongrid.io',
      network_id: '2'
    },
    nile: {
      privateKey: process.env.PRIVATE_KEY_NILE,
      userFeePercentage: 100,
      feeLimit: 1000 * 1e6,
      fullHost: 'https://nile.trongrid.io',
      network_id: '3'
    },
    development: {
      privateKey: '0000000000000000000000000000000000000000000000000000000000000001',
      userFeePercentage: 0,
      feeLimit: 1000 * 1e6,
      fullHost: `http://127.0.0.1:${port}`,
      network_id: '9'
    }
  },
  compilers: {
    solc: {
      version: '0.8.20',      
      settings: {
        optimizer: {
          enabled: true,
          runs: 200
        },
        evmVersion: 'paris',
        viaIR: true,        
      }
    }
  }
};
