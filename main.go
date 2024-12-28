package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math/big"
	"os"

	"github.com/KYRDTeam/v3utils/contracts"

	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/ethclient"
)

var (
	ContractAbi, _ = contracts.V3UtilsMetaData.GetAbi()
	affectedUsers  []AffectedUser
	TraceConfigs   = []struct {
		RpcUrl     string
		StartBlock uint64
		EndBlock   uint64
		BlockStep  uint64
	}{
		// end block is at 00:00 28 Oct 2024 VNT
		{
			// base
			RpcUrl:     "<private rpc url>",
			StartBlock: 23854051,
			EndBlock:   24264727,
			BlockStep:  10000,
		},
		{
			// ethereum
			RpcUrl:     "<private rpc url>",
			StartBlock: 21488107,
			EndBlock:   21495147,
			BlockStep:  5000,
		},
		{
			// polygon
			RpcUrl:     "<private rpc url>",
			StartBlock: 65707170,
			EndBlock:   65992519,
			BlockStep:  10000,
		},
		{
			// bsc
			RpcUrl:     "<private rpc url>",
			StartBlock: 45034212,
			EndBlock:   45245900,
			BlockStep:  10000,
		},
		{
			// arbitrum
			RpcUrl:     "<private rpc url>",
			StartBlock: 285327691,
			EndBlock:   289210279,
			BlockStep:  10000,
		},
		{
			// OP
			RpcUrl:     "<private rpc url>",
			StartBlock: 129372945,
			EndBlock:   129860011,
			BlockStep:  10000,
		},
	}
)

type AffectedUser struct {
	ChainId         *big.Int
	Address         common.Address
	Token           common.Address
	RewardAmount    *big.Int
	DeductedAmount  *big.Int
	RemainingAmount *big.Int
	TxHash          common.Hash
}

func (a *AffectedUser) csv() string {
	return fmt.Sprintf("%s,%s,%s,%s,%s,%s,%s", a.ChainId.String(), a.Address.Hex(), a.Token.Hex(), a.RewardAmount.String(), a.DeductedAmount.String(), a.RemainingAmount.String(), a.TxHash.Hex())
}

func main() {
	for _, config := range TraceConfigs {
		client, err := ethclient.Dial(config.RpcUrl)
		if err != nil {
			panic(err)
		}
		contract, err := contracts.NewV3Utils(common.HexToAddress("0x47edbf72b357fe0556f431609a90d065d594c1eb"), client)
		if err != nil {
			panic(err)
		}
		run(client, contract, config.StartBlock, config.EndBlock, config.BlockStep)
	}
	toCsv()
}

func toCsv() {
	file, err := os.Create("affected_users.csv")
	if err != nil {
		panic(err)
	}
	defer file.Close()
	_, err = file.WriteString("ChainId,Address,Token,RewardAmount,DeductedAmount,RemainingAmount,TxHash\n")
	if err != nil {
		panic(err)
	}
	for _, user := range affectedUsers {
		_, err = file.WriteString(user.csv() + "\n")
		if err != nil {
			panic(err)
		}
	}
}

func run(client *ethclient.Client, contract *contracts.V3Utils, startBlock, endBlock, blockStep uint64) {
	chainId, err := client.ChainID(context.Background())
	if err != nil {
		panic(err)
	}
	fmt.Printf("Chain ID: %v\n", chainId)

	// split into ranges
	for i := startBlock; i < endBlock; i += blockStep {
		fmt.Println("filtering logs from block ", i, " to ", i+blockStep, "for chain ", chainId)
		filterLog(client, contract, i, i+blockStep)
	}
}

func filterLog(client *ethclient.Client, contract *contracts.V3Utils, startBlock, endBlock uint64) {
	logs, err := contract.FilterChangeRange(&bind.FilterOpts{
		Start: startBlock,
		End:   &endBlock,
	}, nil, nil)
	if err != nil {
		panic(err)
	}
	for logs.Next() {
		processTxn(client, contract, logs.Event.Raw.TxHash)
	}
}

func processTxn(client *ethclient.Client, contract *contracts.V3Utils, txHash common.Hash) {
	log.Printf("Processing txn, txHash: %v\n", txHash.Hex())
	txn, _, err := client.TransactionByHash(context.Background(), txHash)
	if err != nil {
		panic(err)
	}
	var unpackedData = make(map[string]any)
	err = ContractAbi.Methods["execute"].Inputs.UnpackIntoMap(unpackedData, txn.Data()[4:])
	if err != nil {
		panic(err)
	}
	jsonData, err := json.Marshal(unpackedData["params"])
	if err != nil {
		panic(err)
	}
	var input struct {
		CompoundFees bool `json:"compoundFees"`
	}
	err = json.Unmarshal(jsonData, &input)
	if err != nil {
		panic(err)
	}
	fmt.Println(input)

	if !input.CompoundFees {
		txReceipt, err := client.TransactionReceipt(context.Background(), txHash)
		if err != nil {
			panic(err)
		}
		for _, log := range txReceipt.Logs {
			// deductFees topic: 0x07b9ff32d43e39b450a13b642c1e93282a8ea460336f1422bddc6164b304c2da
			if log.Topics[0].Hex() == "0x07b9ff32d43e39b450a13b642c1e93282a8ea460336f1422bddc6164b304c2da" {
				logData, err := contract.ParseDeductFees(*log)
				if err != nil {
					panic(err)
				}
				// feeType 2 = Performance fee
				if logData.Data.FeeType == 2 {
					affectedUsers = append(affectedUsers, AffectedUser{
						ChainId:         txn.ChainId(),
						Address:         logData.UserAddress,
						Token:           logData.Data.Token0,
						RewardAmount:    logData.Data.Amount0,
						DeductedAmount:  logData.Data.FeeAmount0,
						RemainingAmount: new(big.Int).Sub(logData.Data.Amount0, logData.Data.FeeAmount0),
						TxHash:          txHash,
					})

					affectedUsers = append(affectedUsers, AffectedUser{
						ChainId:         txn.ChainId(),
						Address:         logData.UserAddress,
						Token:           logData.Data.Token1,
						RewardAmount:    logData.Data.Amount1,
						DeductedAmount:  logData.Data.FeeAmount1,
						RemainingAmount: new(big.Int).Sub(logData.Data.Amount1, logData.Data.FeeAmount1),
						TxHash:          txHash,
					})
				}
			}
		}

	}
}
