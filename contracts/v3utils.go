// Code generated - DO NOT EDIT.
// This file is a generated binding and any manual changes will be lost.

package contracts

import (
	"errors"
	"math/big"
	"strings"

	ethereum "github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/event"
)

// Reference imports to suppress errors if they are not otherwise used.
var (
	_ = errors.New
	_ = big.NewInt
	_ = strings.NewReader
	_ = ethereum.NotFound
	_ = bind.Bind
	_ = common.Big1
	_ = types.BloomLookup
	_ = event.NewSubscription
	_ = abi.ConvertType
)

// CommonDeductFeesEventData is an auto generated low-level Go binding around an user-defined struct.
type CommonDeductFeesEventData struct {
	Token0     common.Address
	Token1     common.Address
	Token2     common.Address
	Amount0    *big.Int
	Amount1    *big.Int
	Amount2    *big.Int
	FeeAmount0 *big.Int
	FeeAmount1 *big.Int
	FeeAmount2 *big.Int
	FeeX64     uint64
	FeeType    uint8
}

// V3AutomationExecuteParams is an auto generated low-level Go binding around an user-defined struct.
type V3AutomationExecuteParams struct {
	Action              uint8
	Protocol            uint8
	Nfpm                common.Address
	TokenId             *big.Int
	Liquidity           *big.Int
	TargetToken         common.Address
	AmountIn0           *big.Int
	AmountOut0Min       *big.Int
	SwapData0           []byte
	AmountIn1           *big.Int
	AmountOut1Min       *big.Int
	SwapData1           []byte
	AmountRemoveMin0    *big.Int
	AmountRemoveMin1    *big.Int
	Deadline            *big.Int
	GasFeeX64           uint64
	LiquidityFeeX64     uint64
	PerformanceFeeX64   uint64
	NewTickLower        *big.Int
	NewTickUpper        *big.Int
	CompoundFees        bool
	AmountAddMin0       *big.Int
	AmountAddMin1       *big.Int
	AbiEncodedUserOrder []byte
	OrderSignature      []byte
}

// V3UtilsMetaData contains all meta data concerning the V3Utils contract.
var V3UtilsMetaData = &bind.MetaData{
	ABI: "[{\"inputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"constructor\"},{\"inputs\":[],\"name\":\"AmountError\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"CollectError\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"EtherSendFailed\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"GetPositionFailed\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"NoEtherToken\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"NoFees\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"NotSupportedAction\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"NotSupportedProtocol\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"NotWETH\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"SameToken\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"SelfSend\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"SlippageError\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"TooMuchEtherSent\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"TooMuchFee\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"TransferError\",\"type\":\"error\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":false,\"internalType\":\"address\",\"name\":\"user\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"bytes\",\"name\":\"order\",\"type\":\"bytes\"},{\"indexed\":false,\"internalType\":\"bytes\",\"name\":\"signature\",\"type\":\"bytes\"}],\"name\":\"CancelOrder\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"nfpm\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"uint256\",\"name\":\"tokenId\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"newTokenId\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"newLiquidity\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"token0Added\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"token1Added\",\"type\":\"uint256\"}],\"name\":\"ChangeRange\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"nfpm\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"uint256\",\"name\":\"tokenId\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint128\",\"name\":\"liquidity\",\"type\":\"uint128\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"amount0\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"amount1\",\"type\":\"uint256\"}],\"name\":\"CompoundFees\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"nfpm\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"uint256\",\"name\":\"tokenId\",\"type\":\"uint256\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"userAddress\",\"type\":\"address\"},{\"components\":[{\"internalType\":\"address\",\"name\":\"token0\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"token1\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"token2\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"amount0\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"amount1\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"amount2\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"feeAmount0\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"feeAmount1\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"feeAmount2\",\"type\":\"uint256\"},{\"internalType\":\"uint64\",\"name\":\"feeX64\",\"type\":\"uint64\"},{\"internalType\":\"enumCommon.FeeType\",\"name\":\"feeType\",\"type\":\"uint8\"}],\"indexed\":false,\"internalType\":\"structCommon.DeductFeesEventData\",\"name\":\"data\",\"type\":\"tuple\"}],\"name\":\"DeductFees\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":false,\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"}],\"name\":\"Paused\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"bytes32\",\"name\":\"role\",\"type\":\"bytes32\"},{\"indexed\":true,\"internalType\":\"bytes32\",\"name\":\"previousAdminRole\",\"type\":\"bytes32\"},{\"indexed\":true,\"internalType\":\"bytes32\",\"name\":\"newAdminRole\",\"type\":\"bytes32\"}],\"name\":\"RoleAdminChanged\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"bytes32\",\"name\":\"role\",\"type\":\"bytes32\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"sender\",\"type\":\"address\"}],\"name\":\"RoleGranted\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"bytes32\",\"name\":\"role\",\"type\":\"bytes32\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"sender\",\"type\":\"address\"}],\"name\":\"RoleRevoked\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"tokenIn\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"tokenOut\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"amountIn\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"amountOut\",\"type\":\"uint256\"}],\"name\":\"Swap\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"nfpm\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"uint256\",\"name\":\"tokenId\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint128\",\"name\":\"liquidity\",\"type\":\"uint128\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"amount0\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"amount1\",\"type\":\"uint256\"}],\"name\":\"SwapAndIncreaseLiquidity\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"nfpm\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"uint256\",\"name\":\"tokenId\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint128\",\"name\":\"liquidity\",\"type\":\"uint128\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"amount0\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"amount1\",\"type\":\"uint256\"}],\"name\":\"SwapAndMint\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":false,\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"}],\"name\":\"Unpaused\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"nfpm\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"uint256\",\"name\":\"tokenId\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"address\",\"name\":\"token\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"amount\",\"type\":\"uint256\"}],\"name\":\"WithdrawAndCollectAndSwap\",\"type\":\"event\"},{\"inputs\":[],\"name\":\"ADMIN_ROLE\",\"outputs\":[{\"internalType\":\"bytes32\",\"name\":\"\",\"type\":\"bytes32\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"DEFAULT_ADMIN_ROLE\",\"outputs\":[{\"internalType\":\"bytes32\",\"name\":\"\",\"type\":\"bytes32\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"DOMAIN_SEPARATOR\",\"outputs\":[{\"internalType\":\"bytes32\",\"name\":\"\",\"type\":\"bytes32\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"FEE_TAKER\",\"outputs\":[{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"OPERATOR_ROLE\",\"outputs\":[{\"internalType\":\"bytes32\",\"name\":\"\",\"type\":\"bytes32\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"WITHDRAWER_ROLE\",\"outputs\":[{\"internalType\":\"bytes32\",\"name\":\"\",\"type\":\"bytes32\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"bytes\",\"name\":\"abiEncodedUserOrder\",\"type\":\"bytes\"},{\"internalType\":\"bytes\",\"name\":\"orderSignature\",\"type\":\"bytes\"}],\"name\":\"cancelOrder\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"components\":[{\"internalType\":\"enumV3Automation.Action\",\"name\":\"action\",\"type\":\"uint8\"},{\"internalType\":\"enumCommon.Protocol\",\"name\":\"protocol\",\"type\":\"uint8\"},{\"internalType\":\"contractINonfungiblePositionManager\",\"name\":\"nfpm\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"tokenId\",\"type\":\"uint256\"},{\"internalType\":\"uint128\",\"name\":\"liquidity\",\"type\":\"uint128\"},{\"internalType\":\"address\",\"name\":\"targetToken\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"amountIn0\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"amountOut0Min\",\"type\":\"uint256\"},{\"internalType\":\"bytes\",\"name\":\"swapData0\",\"type\":\"bytes\"},{\"internalType\":\"uint256\",\"name\":\"amountIn1\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"amountOut1Min\",\"type\":\"uint256\"},{\"internalType\":\"bytes\",\"name\":\"swapData1\",\"type\":\"bytes\"},{\"internalType\":\"uint256\",\"name\":\"amountRemoveMin0\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"amountRemoveMin1\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"deadline\",\"type\":\"uint256\"},{\"internalType\":\"uint64\",\"name\":\"gasFeeX64\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"liquidityFeeX64\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"performanceFeeX64\",\"type\":\"uint64\"},{\"internalType\":\"int24\",\"name\":\"newTickLower\",\"type\":\"int24\"},{\"internalType\":\"int24\",\"name\":\"newTickUpper\",\"type\":\"int24\"},{\"internalType\":\"bool\",\"name\":\"compoundFees\",\"type\":\"bool\"},{\"internalType\":\"uint256\",\"name\":\"amountAddMin0\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"amountAddMin1\",\"type\":\"uint256\"},{\"internalType\":\"bytes\",\"name\":\"abiEncodedUserOrder\",\"type\":\"bytes\"},{\"internalType\":\"bytes\",\"name\":\"orderSignature\",\"type\":\"bytes\"}],\"internalType\":\"structV3Automation.ExecuteParams\",\"name\":\"params\",\"type\":\"tuple\"}],\"name\":\"execute\",\"outputs\":[],\"stateMutability\":\"payable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"enumCommon.FeeType\",\"name\":\"feeType\",\"type\":\"uint8\"}],\"name\":\"getMaxFeeX64\",\"outputs\":[{\"internalType\":\"uint64\",\"name\":\"\",\"type\":\"uint64\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"bytes32\",\"name\":\"role\",\"type\":\"bytes32\"}],\"name\":\"getRoleAdmin\",\"outputs\":[{\"internalType\":\"bytes32\",\"name\":\"\",\"type\":\"bytes32\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"bytes32\",\"name\":\"role\",\"type\":\"bytes32\"},{\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"}],\"name\":\"grantRole\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"bytes32\",\"name\":\"role\",\"type\":\"bytes32\"},{\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"}],\"name\":\"hasRole\",\"outputs\":[{\"internalType\":\"bool\",\"name\":\"\",\"type\":\"bool\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"_swapRouter\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"admin\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"withdrawer\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"feeTaker\",\"type\":\"address\"},{\"internalType\":\"address[]\",\"name\":\"whitelistedNfpms\",\"type\":\"address[]\"}],\"name\":\"initialize\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"bytes\",\"name\":\"orderSignature\",\"type\":\"bytes\"}],\"name\":\"isOrderCancelled\",\"outputs\":[{\"internalType\":\"bool\",\"name\":\"\",\"type\":\"bool\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"pause\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"paused\",\"outputs\":[{\"internalType\":\"bool\",\"name\":\"\",\"type\":\"bool\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"bytes32\",\"name\":\"role\",\"type\":\"bytes32\"},{\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"}],\"name\":\"renounceRole\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"bytes32\",\"name\":\"role\",\"type\":\"bytes32\"},{\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"}],\"name\":\"revokeRole\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"feeTaker\",\"type\":\"address\"}],\"name\":\"setFeeTaker\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"enumCommon.FeeType\",\"name\":\"feeType\",\"type\":\"uint8\"},{\"internalType\":\"uint64\",\"name\":\"feex64\",\"type\":\"uint64\"}],\"name\":\"setMaxFeeX64\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address[]\",\"name\":\"nfpms\",\"type\":\"address[]\"},{\"internalType\":\"bool\",\"name\":\"isWhitelist\",\"type\":\"bool\"}],\"name\":\"setWhitelistNfpm\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"bytes4\",\"name\":\"interfaceId\",\"type\":\"bytes4\"}],\"name\":\"supportsInterface\",\"outputs\":[{\"internalType\":\"bool\",\"name\":\"\",\"type\":\"bool\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"swapRouter\",\"outputs\":[{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"unpause\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"contractIERC20[]\",\"name\":\"tokens\",\"type\":\"address[]\"},{\"internalType\":\"address\",\"name\":\"to\",\"type\":\"address\"}],\"name\":\"withdrawERC20\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"contractINonfungiblePositionManager\",\"name\":\"nfpm\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"tokenId\",\"type\":\"uint256\"},{\"internalType\":\"address\",\"name\":\"to\",\"type\":\"address\"}],\"name\":\"withdrawERC721\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"to\",\"type\":\"address\"}],\"name\":\"withdrawNative\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"stateMutability\":\"payable\",\"type\":\"receive\"}]",
}

// V3UtilsABI is the input ABI used to generate the binding from.
// Deprecated: Use V3UtilsMetaData.ABI instead.
var V3UtilsABI = V3UtilsMetaData.ABI

// V3Utils is an auto generated Go binding around an Ethereum contract.
type V3Utils struct {
	V3UtilsCaller     // Read-only binding to the contract
	V3UtilsTransactor // Write-only binding to the contract
	V3UtilsFilterer   // Log filterer for contract events
}

// V3UtilsCaller is an auto generated read-only Go binding around an Ethereum contract.
type V3UtilsCaller struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// V3UtilsTransactor is an auto generated write-only Go binding around an Ethereum contract.
type V3UtilsTransactor struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// V3UtilsFilterer is an auto generated log filtering Go binding around an Ethereum contract events.
type V3UtilsFilterer struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// V3UtilsSession is an auto generated Go binding around an Ethereum contract,
// with pre-set call and transact options.
type V3UtilsSession struct {
	Contract     *V3Utils          // Generic contract binding to set the session for
	CallOpts     bind.CallOpts     // Call options to use throughout this session
	TransactOpts bind.TransactOpts // Transaction auth options to use throughout this session
}

// V3UtilsCallerSession is an auto generated read-only Go binding around an Ethereum contract,
// with pre-set call options.
type V3UtilsCallerSession struct {
	Contract *V3UtilsCaller // Generic contract caller binding to set the session for
	CallOpts bind.CallOpts  // Call options to use throughout this session
}

// V3UtilsTransactorSession is an auto generated write-only Go binding around an Ethereum contract,
// with pre-set transact options.
type V3UtilsTransactorSession struct {
	Contract     *V3UtilsTransactor // Generic contract transactor binding to set the session for
	TransactOpts bind.TransactOpts  // Transaction auth options to use throughout this session
}

// V3UtilsRaw is an auto generated low-level Go binding around an Ethereum contract.
type V3UtilsRaw struct {
	Contract *V3Utils // Generic contract binding to access the raw methods on
}

// V3UtilsCallerRaw is an auto generated low-level read-only Go binding around an Ethereum contract.
type V3UtilsCallerRaw struct {
	Contract *V3UtilsCaller // Generic read-only contract binding to access the raw methods on
}

// V3UtilsTransactorRaw is an auto generated low-level write-only Go binding around an Ethereum contract.
type V3UtilsTransactorRaw struct {
	Contract *V3UtilsTransactor // Generic write-only contract binding to access the raw methods on
}

// NewV3Utils creates a new instance of V3Utils, bound to a specific deployed contract.
func NewV3Utils(address common.Address, backend bind.ContractBackend) (*V3Utils, error) {
	contract, err := bindV3Utils(address, backend, backend, backend)
	if err != nil {
		return nil, err
	}
	return &V3Utils{V3UtilsCaller: V3UtilsCaller{contract: contract}, V3UtilsTransactor: V3UtilsTransactor{contract: contract}, V3UtilsFilterer: V3UtilsFilterer{contract: contract}}, nil
}

// NewV3UtilsCaller creates a new read-only instance of V3Utils, bound to a specific deployed contract.
func NewV3UtilsCaller(address common.Address, caller bind.ContractCaller) (*V3UtilsCaller, error) {
	contract, err := bindV3Utils(address, caller, nil, nil)
	if err != nil {
		return nil, err
	}
	return &V3UtilsCaller{contract: contract}, nil
}

// NewV3UtilsTransactor creates a new write-only instance of V3Utils, bound to a specific deployed contract.
func NewV3UtilsTransactor(address common.Address, transactor bind.ContractTransactor) (*V3UtilsTransactor, error) {
	contract, err := bindV3Utils(address, nil, transactor, nil)
	if err != nil {
		return nil, err
	}
	return &V3UtilsTransactor{contract: contract}, nil
}

// NewV3UtilsFilterer creates a new log filterer instance of V3Utils, bound to a specific deployed contract.
func NewV3UtilsFilterer(address common.Address, filterer bind.ContractFilterer) (*V3UtilsFilterer, error) {
	contract, err := bindV3Utils(address, nil, nil, filterer)
	if err != nil {
		return nil, err
	}
	return &V3UtilsFilterer{contract: contract}, nil
}

// bindV3Utils binds a generic wrapper to an already deployed contract.
func bindV3Utils(address common.Address, caller bind.ContractCaller, transactor bind.ContractTransactor, filterer bind.ContractFilterer) (*bind.BoundContract, error) {
	parsed, err := V3UtilsMetaData.GetAbi()
	if err != nil {
		return nil, err
	}
	return bind.NewBoundContract(address, *parsed, caller, transactor, filterer), nil
}

// Call invokes the (constant) contract method with params as input values and
// sets the output to result. The result type might be a single field for simple
// returns, a slice of interfaces for anonymous returns and a struct for named
// returns.
func (_V3Utils *V3UtilsRaw) Call(opts *bind.CallOpts, result *[]interface{}, method string, params ...interface{}) error {
	return _V3Utils.Contract.V3UtilsCaller.contract.Call(opts, result, method, params...)
}

// Transfer initiates a plain transaction to move funds to the contract, calling
// its default method if one is available.
func (_V3Utils *V3UtilsRaw) Transfer(opts *bind.TransactOpts) (*types.Transaction, error) {
	return _V3Utils.Contract.V3UtilsTransactor.contract.Transfer(opts)
}

// Transact invokes the (paid) contract method with params as input values.
func (_V3Utils *V3UtilsRaw) Transact(opts *bind.TransactOpts, method string, params ...interface{}) (*types.Transaction, error) {
	return _V3Utils.Contract.V3UtilsTransactor.contract.Transact(opts, method, params...)
}

// Call invokes the (constant) contract method with params as input values and
// sets the output to result. The result type might be a single field for simple
// returns, a slice of interfaces for anonymous returns and a struct for named
// returns.
func (_V3Utils *V3UtilsCallerRaw) Call(opts *bind.CallOpts, result *[]interface{}, method string, params ...interface{}) error {
	return _V3Utils.Contract.contract.Call(opts, result, method, params...)
}

// Transfer initiates a plain transaction to move funds to the contract, calling
// its default method if one is available.
func (_V3Utils *V3UtilsTransactorRaw) Transfer(opts *bind.TransactOpts) (*types.Transaction, error) {
	return _V3Utils.Contract.contract.Transfer(opts)
}

// Transact invokes the (paid) contract method with params as input values.
func (_V3Utils *V3UtilsTransactorRaw) Transact(opts *bind.TransactOpts, method string, params ...interface{}) (*types.Transaction, error) {
	return _V3Utils.Contract.contract.Transact(opts, method, params...)
}

// ADMINROLE is a free data retrieval call binding the contract method 0x75b238fc.
//
// Solidity: function ADMIN_ROLE() view returns(bytes32)
func (_V3Utils *V3UtilsCaller) ADMINROLE(opts *bind.CallOpts) ([32]byte, error) {
	var out []interface{}
	err := _V3Utils.contract.Call(opts, &out, "ADMIN_ROLE")

	if err != nil {
		return *new([32]byte), err
	}

	out0 := *abi.ConvertType(out[0], new([32]byte)).(*[32]byte)

	return out0, err

}

// ADMINROLE is a free data retrieval call binding the contract method 0x75b238fc.
//
// Solidity: function ADMIN_ROLE() view returns(bytes32)
func (_V3Utils *V3UtilsSession) ADMINROLE() ([32]byte, error) {
	return _V3Utils.Contract.ADMINROLE(&_V3Utils.CallOpts)
}

// ADMINROLE is a free data retrieval call binding the contract method 0x75b238fc.
//
// Solidity: function ADMIN_ROLE() view returns(bytes32)
func (_V3Utils *V3UtilsCallerSession) ADMINROLE() ([32]byte, error) {
	return _V3Utils.Contract.ADMINROLE(&_V3Utils.CallOpts)
}

// DEFAULTADMINROLE is a free data retrieval call binding the contract method 0xa217fddf.
//
// Solidity: function DEFAULT_ADMIN_ROLE() view returns(bytes32)
func (_V3Utils *V3UtilsCaller) DEFAULTADMINROLE(opts *bind.CallOpts) ([32]byte, error) {
	var out []interface{}
	err := _V3Utils.contract.Call(opts, &out, "DEFAULT_ADMIN_ROLE")

	if err != nil {
		return *new([32]byte), err
	}

	out0 := *abi.ConvertType(out[0], new([32]byte)).(*[32]byte)

	return out0, err

}

// DEFAULTADMINROLE is a free data retrieval call binding the contract method 0xa217fddf.
//
// Solidity: function DEFAULT_ADMIN_ROLE() view returns(bytes32)
func (_V3Utils *V3UtilsSession) DEFAULTADMINROLE() ([32]byte, error) {
	return _V3Utils.Contract.DEFAULTADMINROLE(&_V3Utils.CallOpts)
}

// DEFAULTADMINROLE is a free data retrieval call binding the contract method 0xa217fddf.
//
// Solidity: function DEFAULT_ADMIN_ROLE() view returns(bytes32)
func (_V3Utils *V3UtilsCallerSession) DEFAULTADMINROLE() ([32]byte, error) {
	return _V3Utils.Contract.DEFAULTADMINROLE(&_V3Utils.CallOpts)
}

// DOMAINSEPARATOR is a free data retrieval call binding the contract method 0x3644e515.
//
// Solidity: function DOMAIN_SEPARATOR() view returns(bytes32)
func (_V3Utils *V3UtilsCaller) DOMAINSEPARATOR(opts *bind.CallOpts) ([32]byte, error) {
	var out []interface{}
	err := _V3Utils.contract.Call(opts, &out, "DOMAIN_SEPARATOR")

	if err != nil {
		return *new([32]byte), err
	}

	out0 := *abi.ConvertType(out[0], new([32]byte)).(*[32]byte)

	return out0, err

}

// DOMAINSEPARATOR is a free data retrieval call binding the contract method 0x3644e515.
//
// Solidity: function DOMAIN_SEPARATOR() view returns(bytes32)
func (_V3Utils *V3UtilsSession) DOMAINSEPARATOR() ([32]byte, error) {
	return _V3Utils.Contract.DOMAINSEPARATOR(&_V3Utils.CallOpts)
}

// DOMAINSEPARATOR is a free data retrieval call binding the contract method 0x3644e515.
//
// Solidity: function DOMAIN_SEPARATOR() view returns(bytes32)
func (_V3Utils *V3UtilsCallerSession) DOMAINSEPARATOR() ([32]byte, error) {
	return _V3Utils.Contract.DOMAINSEPARATOR(&_V3Utils.CallOpts)
}

// FEETAKER is a free data retrieval call binding the contract method 0x552e94a9.
//
// Solidity: function FEE_TAKER() view returns(address)
func (_V3Utils *V3UtilsCaller) FEETAKER(opts *bind.CallOpts) (common.Address, error) {
	var out []interface{}
	err := _V3Utils.contract.Call(opts, &out, "FEE_TAKER")

	if err != nil {
		return *new(common.Address), err
	}

	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)

	return out0, err

}

// FEETAKER is a free data retrieval call binding the contract method 0x552e94a9.
//
// Solidity: function FEE_TAKER() view returns(address)
func (_V3Utils *V3UtilsSession) FEETAKER() (common.Address, error) {
	return _V3Utils.Contract.FEETAKER(&_V3Utils.CallOpts)
}

// FEETAKER is a free data retrieval call binding the contract method 0x552e94a9.
//
// Solidity: function FEE_TAKER() view returns(address)
func (_V3Utils *V3UtilsCallerSession) FEETAKER() (common.Address, error) {
	return _V3Utils.Contract.FEETAKER(&_V3Utils.CallOpts)
}

// OPERATORROLE is a free data retrieval call binding the contract method 0xf5b541a6.
//
// Solidity: function OPERATOR_ROLE() view returns(bytes32)
func (_V3Utils *V3UtilsCaller) OPERATORROLE(opts *bind.CallOpts) ([32]byte, error) {
	var out []interface{}
	err := _V3Utils.contract.Call(opts, &out, "OPERATOR_ROLE")

	if err != nil {
		return *new([32]byte), err
	}

	out0 := *abi.ConvertType(out[0], new([32]byte)).(*[32]byte)

	return out0, err

}

// OPERATORROLE is a free data retrieval call binding the contract method 0xf5b541a6.
//
// Solidity: function OPERATOR_ROLE() view returns(bytes32)
func (_V3Utils *V3UtilsSession) OPERATORROLE() ([32]byte, error) {
	return _V3Utils.Contract.OPERATORROLE(&_V3Utils.CallOpts)
}

// OPERATORROLE is a free data retrieval call binding the contract method 0xf5b541a6.
//
// Solidity: function OPERATOR_ROLE() view returns(bytes32)
func (_V3Utils *V3UtilsCallerSession) OPERATORROLE() ([32]byte, error) {
	return _V3Utils.Contract.OPERATORROLE(&_V3Utils.CallOpts)
}

// WITHDRAWERROLE is a free data retrieval call binding the contract method 0x85f438c1.
//
// Solidity: function WITHDRAWER_ROLE() view returns(bytes32)
func (_V3Utils *V3UtilsCaller) WITHDRAWERROLE(opts *bind.CallOpts) ([32]byte, error) {
	var out []interface{}
	err := _V3Utils.contract.Call(opts, &out, "WITHDRAWER_ROLE")

	if err != nil {
		return *new([32]byte), err
	}

	out0 := *abi.ConvertType(out[0], new([32]byte)).(*[32]byte)

	return out0, err

}

// WITHDRAWERROLE is a free data retrieval call binding the contract method 0x85f438c1.
//
// Solidity: function WITHDRAWER_ROLE() view returns(bytes32)
func (_V3Utils *V3UtilsSession) WITHDRAWERROLE() ([32]byte, error) {
	return _V3Utils.Contract.WITHDRAWERROLE(&_V3Utils.CallOpts)
}

// WITHDRAWERROLE is a free data retrieval call binding the contract method 0x85f438c1.
//
// Solidity: function WITHDRAWER_ROLE() view returns(bytes32)
func (_V3Utils *V3UtilsCallerSession) WITHDRAWERROLE() ([32]byte, error) {
	return _V3Utils.Contract.WITHDRAWERROLE(&_V3Utils.CallOpts)
}

// GetMaxFeeX64 is a free data retrieval call binding the contract method 0xc8bfbbbe.
//
// Solidity: function getMaxFeeX64(uint8 feeType) view returns(uint64)
func (_V3Utils *V3UtilsCaller) GetMaxFeeX64(opts *bind.CallOpts, feeType uint8) (uint64, error) {
	var out []interface{}
	err := _V3Utils.contract.Call(opts, &out, "getMaxFeeX64", feeType)

	if err != nil {
		return *new(uint64), err
	}

	out0 := *abi.ConvertType(out[0], new(uint64)).(*uint64)

	return out0, err

}

// GetMaxFeeX64 is a free data retrieval call binding the contract method 0xc8bfbbbe.
//
// Solidity: function getMaxFeeX64(uint8 feeType) view returns(uint64)
func (_V3Utils *V3UtilsSession) GetMaxFeeX64(feeType uint8) (uint64, error) {
	return _V3Utils.Contract.GetMaxFeeX64(&_V3Utils.CallOpts, feeType)
}

// GetMaxFeeX64 is a free data retrieval call binding the contract method 0xc8bfbbbe.
//
// Solidity: function getMaxFeeX64(uint8 feeType) view returns(uint64)
func (_V3Utils *V3UtilsCallerSession) GetMaxFeeX64(feeType uint8) (uint64, error) {
	return _V3Utils.Contract.GetMaxFeeX64(&_V3Utils.CallOpts, feeType)
}

// GetRoleAdmin is a free data retrieval call binding the contract method 0x248a9ca3.
//
// Solidity: function getRoleAdmin(bytes32 role) view returns(bytes32)
func (_V3Utils *V3UtilsCaller) GetRoleAdmin(opts *bind.CallOpts, role [32]byte) ([32]byte, error) {
	var out []interface{}
	err := _V3Utils.contract.Call(opts, &out, "getRoleAdmin", role)

	if err != nil {
		return *new([32]byte), err
	}

	out0 := *abi.ConvertType(out[0], new([32]byte)).(*[32]byte)

	return out0, err

}

// GetRoleAdmin is a free data retrieval call binding the contract method 0x248a9ca3.
//
// Solidity: function getRoleAdmin(bytes32 role) view returns(bytes32)
func (_V3Utils *V3UtilsSession) GetRoleAdmin(role [32]byte) ([32]byte, error) {
	return _V3Utils.Contract.GetRoleAdmin(&_V3Utils.CallOpts, role)
}

// GetRoleAdmin is a free data retrieval call binding the contract method 0x248a9ca3.
//
// Solidity: function getRoleAdmin(bytes32 role) view returns(bytes32)
func (_V3Utils *V3UtilsCallerSession) GetRoleAdmin(role [32]byte) ([32]byte, error) {
	return _V3Utils.Contract.GetRoleAdmin(&_V3Utils.CallOpts, role)
}

// HasRole is a free data retrieval call binding the contract method 0x91d14854.
//
// Solidity: function hasRole(bytes32 role, address account) view returns(bool)
func (_V3Utils *V3UtilsCaller) HasRole(opts *bind.CallOpts, role [32]byte, account common.Address) (bool, error) {
	var out []interface{}
	err := _V3Utils.contract.Call(opts, &out, "hasRole", role, account)

	if err != nil {
		return *new(bool), err
	}

	out0 := *abi.ConvertType(out[0], new(bool)).(*bool)

	return out0, err

}

// HasRole is a free data retrieval call binding the contract method 0x91d14854.
//
// Solidity: function hasRole(bytes32 role, address account) view returns(bool)
func (_V3Utils *V3UtilsSession) HasRole(role [32]byte, account common.Address) (bool, error) {
	return _V3Utils.Contract.HasRole(&_V3Utils.CallOpts, role, account)
}

// HasRole is a free data retrieval call binding the contract method 0x91d14854.
//
// Solidity: function hasRole(bytes32 role, address account) view returns(bool)
func (_V3Utils *V3UtilsCallerSession) HasRole(role [32]byte, account common.Address) (bool, error) {
	return _V3Utils.Contract.HasRole(&_V3Utils.CallOpts, role, account)
}

// IsOrderCancelled is a free data retrieval call binding the contract method 0x563166a9.
//
// Solidity: function isOrderCancelled(bytes orderSignature) view returns(bool)
func (_V3Utils *V3UtilsCaller) IsOrderCancelled(opts *bind.CallOpts, orderSignature []byte) (bool, error) {
	var out []interface{}
	err := _V3Utils.contract.Call(opts, &out, "isOrderCancelled", orderSignature)

	if err != nil {
		return *new(bool), err
	}

	out0 := *abi.ConvertType(out[0], new(bool)).(*bool)

	return out0, err

}

// IsOrderCancelled is a free data retrieval call binding the contract method 0x563166a9.
//
// Solidity: function isOrderCancelled(bytes orderSignature) view returns(bool)
func (_V3Utils *V3UtilsSession) IsOrderCancelled(orderSignature []byte) (bool, error) {
	return _V3Utils.Contract.IsOrderCancelled(&_V3Utils.CallOpts, orderSignature)
}

// IsOrderCancelled is a free data retrieval call binding the contract method 0x563166a9.
//
// Solidity: function isOrderCancelled(bytes orderSignature) view returns(bool)
func (_V3Utils *V3UtilsCallerSession) IsOrderCancelled(orderSignature []byte) (bool, error) {
	return _V3Utils.Contract.IsOrderCancelled(&_V3Utils.CallOpts, orderSignature)
}

// Paused is a free data retrieval call binding the contract method 0x5c975abb.
//
// Solidity: function paused() view returns(bool)
func (_V3Utils *V3UtilsCaller) Paused(opts *bind.CallOpts) (bool, error) {
	var out []interface{}
	err := _V3Utils.contract.Call(opts, &out, "paused")

	if err != nil {
		return *new(bool), err
	}

	out0 := *abi.ConvertType(out[0], new(bool)).(*bool)

	return out0, err

}

// Paused is a free data retrieval call binding the contract method 0x5c975abb.
//
// Solidity: function paused() view returns(bool)
func (_V3Utils *V3UtilsSession) Paused() (bool, error) {
	return _V3Utils.Contract.Paused(&_V3Utils.CallOpts)
}

// Paused is a free data retrieval call binding the contract method 0x5c975abb.
//
// Solidity: function paused() view returns(bool)
func (_V3Utils *V3UtilsCallerSession) Paused() (bool, error) {
	return _V3Utils.Contract.Paused(&_V3Utils.CallOpts)
}

// SupportsInterface is a free data retrieval call binding the contract method 0x01ffc9a7.
//
// Solidity: function supportsInterface(bytes4 interfaceId) view returns(bool)
func (_V3Utils *V3UtilsCaller) SupportsInterface(opts *bind.CallOpts, interfaceId [4]byte) (bool, error) {
	var out []interface{}
	err := _V3Utils.contract.Call(opts, &out, "supportsInterface", interfaceId)

	if err != nil {
		return *new(bool), err
	}

	out0 := *abi.ConvertType(out[0], new(bool)).(*bool)

	return out0, err

}

// SupportsInterface is a free data retrieval call binding the contract method 0x01ffc9a7.
//
// Solidity: function supportsInterface(bytes4 interfaceId) view returns(bool)
func (_V3Utils *V3UtilsSession) SupportsInterface(interfaceId [4]byte) (bool, error) {
	return _V3Utils.Contract.SupportsInterface(&_V3Utils.CallOpts, interfaceId)
}

// SupportsInterface is a free data retrieval call binding the contract method 0x01ffc9a7.
//
// Solidity: function supportsInterface(bytes4 interfaceId) view returns(bool)
func (_V3Utils *V3UtilsCallerSession) SupportsInterface(interfaceId [4]byte) (bool, error) {
	return _V3Utils.Contract.SupportsInterface(&_V3Utils.CallOpts, interfaceId)
}

// SwapRouter is a free data retrieval call binding the contract method 0xc31c9c07.
//
// Solidity: function swapRouter() view returns(address)
func (_V3Utils *V3UtilsCaller) SwapRouter(opts *bind.CallOpts) (common.Address, error) {
	var out []interface{}
	err := _V3Utils.contract.Call(opts, &out, "swapRouter")

	if err != nil {
		return *new(common.Address), err
	}

	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)

	return out0, err

}

// SwapRouter is a free data retrieval call binding the contract method 0xc31c9c07.
//
// Solidity: function swapRouter() view returns(address)
func (_V3Utils *V3UtilsSession) SwapRouter() (common.Address, error) {
	return _V3Utils.Contract.SwapRouter(&_V3Utils.CallOpts)
}

// SwapRouter is a free data retrieval call binding the contract method 0xc31c9c07.
//
// Solidity: function swapRouter() view returns(address)
func (_V3Utils *V3UtilsCallerSession) SwapRouter() (common.Address, error) {
	return _V3Utils.Contract.SwapRouter(&_V3Utils.CallOpts)
}

// CancelOrder is a paid mutator transaction binding the contract method 0x7ae0c2ec.
//
// Solidity: function cancelOrder(bytes abiEncodedUserOrder, bytes orderSignature) returns()
func (_V3Utils *V3UtilsTransactor) CancelOrder(opts *bind.TransactOpts, abiEncodedUserOrder []byte, orderSignature []byte) (*types.Transaction, error) {
	return _V3Utils.contract.Transact(opts, "cancelOrder", abiEncodedUserOrder, orderSignature)
}

// CancelOrder is a paid mutator transaction binding the contract method 0x7ae0c2ec.
//
// Solidity: function cancelOrder(bytes abiEncodedUserOrder, bytes orderSignature) returns()
func (_V3Utils *V3UtilsSession) CancelOrder(abiEncodedUserOrder []byte, orderSignature []byte) (*types.Transaction, error) {
	return _V3Utils.Contract.CancelOrder(&_V3Utils.TransactOpts, abiEncodedUserOrder, orderSignature)
}

// CancelOrder is a paid mutator transaction binding the contract method 0x7ae0c2ec.
//
// Solidity: function cancelOrder(bytes abiEncodedUserOrder, bytes orderSignature) returns()
func (_V3Utils *V3UtilsTransactorSession) CancelOrder(abiEncodedUserOrder []byte, orderSignature []byte) (*types.Transaction, error) {
	return _V3Utils.Contract.CancelOrder(&_V3Utils.TransactOpts, abiEncodedUserOrder, orderSignature)
}

// Execute is a paid mutator transaction binding the contract method 0xe32bbc9e.
//
// Solidity: function execute((uint8,uint8,address,uint256,uint128,address,uint256,uint256,bytes,uint256,uint256,bytes,uint256,uint256,uint256,uint64,uint64,uint64,int24,int24,bool,uint256,uint256,bytes,bytes) params) payable returns()
func (_V3Utils *V3UtilsTransactor) Execute(opts *bind.TransactOpts, params V3AutomationExecuteParams) (*types.Transaction, error) {
	return _V3Utils.contract.Transact(opts, "execute", params)
}

// Execute is a paid mutator transaction binding the contract method 0xe32bbc9e.
//
// Solidity: function execute((uint8,uint8,address,uint256,uint128,address,uint256,uint256,bytes,uint256,uint256,bytes,uint256,uint256,uint256,uint64,uint64,uint64,int24,int24,bool,uint256,uint256,bytes,bytes) params) payable returns()
func (_V3Utils *V3UtilsSession) Execute(params V3AutomationExecuteParams) (*types.Transaction, error) {
	return _V3Utils.Contract.Execute(&_V3Utils.TransactOpts, params)
}

// Execute is a paid mutator transaction binding the contract method 0xe32bbc9e.
//
// Solidity: function execute((uint8,uint8,address,uint256,uint128,address,uint256,uint256,bytes,uint256,uint256,bytes,uint256,uint256,uint256,uint64,uint64,uint64,int24,int24,bool,uint256,uint256,bytes,bytes) params) payable returns()
func (_V3Utils *V3UtilsTransactorSession) Execute(params V3AutomationExecuteParams) (*types.Transaction, error) {
	return _V3Utils.Contract.Execute(&_V3Utils.TransactOpts, params)
}

// GrantRole is a paid mutator transaction binding the contract method 0x2f2ff15d.
//
// Solidity: function grantRole(bytes32 role, address account) returns()
func (_V3Utils *V3UtilsTransactor) GrantRole(opts *bind.TransactOpts, role [32]byte, account common.Address) (*types.Transaction, error) {
	return _V3Utils.contract.Transact(opts, "grantRole", role, account)
}

// GrantRole is a paid mutator transaction binding the contract method 0x2f2ff15d.
//
// Solidity: function grantRole(bytes32 role, address account) returns()
func (_V3Utils *V3UtilsSession) GrantRole(role [32]byte, account common.Address) (*types.Transaction, error) {
	return _V3Utils.Contract.GrantRole(&_V3Utils.TransactOpts, role, account)
}

// GrantRole is a paid mutator transaction binding the contract method 0x2f2ff15d.
//
// Solidity: function grantRole(bytes32 role, address account) returns()
func (_V3Utils *V3UtilsTransactorSession) GrantRole(role [32]byte, account common.Address) (*types.Transaction, error) {
	return _V3Utils.Contract.GrantRole(&_V3Utils.TransactOpts, role, account)
}

// Initialize is a paid mutator transaction binding the contract method 0xf8453e7c.
//
// Solidity: function initialize(address _swapRouter, address admin, address withdrawer, address feeTaker, address[] whitelistedNfpms) returns()
func (_V3Utils *V3UtilsTransactor) Initialize(opts *bind.TransactOpts, _swapRouter common.Address, admin common.Address, withdrawer common.Address, feeTaker common.Address, whitelistedNfpms []common.Address) (*types.Transaction, error) {
	return _V3Utils.contract.Transact(opts, "initialize", _swapRouter, admin, withdrawer, feeTaker, whitelistedNfpms)
}

// Initialize is a paid mutator transaction binding the contract method 0xf8453e7c.
//
// Solidity: function initialize(address _swapRouter, address admin, address withdrawer, address feeTaker, address[] whitelistedNfpms) returns()
func (_V3Utils *V3UtilsSession) Initialize(_swapRouter common.Address, admin common.Address, withdrawer common.Address, feeTaker common.Address, whitelistedNfpms []common.Address) (*types.Transaction, error) {
	return _V3Utils.Contract.Initialize(&_V3Utils.TransactOpts, _swapRouter, admin, withdrawer, feeTaker, whitelistedNfpms)
}

// Initialize is a paid mutator transaction binding the contract method 0xf8453e7c.
//
// Solidity: function initialize(address _swapRouter, address admin, address withdrawer, address feeTaker, address[] whitelistedNfpms) returns()
func (_V3Utils *V3UtilsTransactorSession) Initialize(_swapRouter common.Address, admin common.Address, withdrawer common.Address, feeTaker common.Address, whitelistedNfpms []common.Address) (*types.Transaction, error) {
	return _V3Utils.Contract.Initialize(&_V3Utils.TransactOpts, _swapRouter, admin, withdrawer, feeTaker, whitelistedNfpms)
}

// Pause is a paid mutator transaction binding the contract method 0x8456cb59.
//
// Solidity: function pause() returns()
func (_V3Utils *V3UtilsTransactor) Pause(opts *bind.TransactOpts) (*types.Transaction, error) {
	return _V3Utils.contract.Transact(opts, "pause")
}

// Pause is a paid mutator transaction binding the contract method 0x8456cb59.
//
// Solidity: function pause() returns()
func (_V3Utils *V3UtilsSession) Pause() (*types.Transaction, error) {
	return _V3Utils.Contract.Pause(&_V3Utils.TransactOpts)
}

// Pause is a paid mutator transaction binding the contract method 0x8456cb59.
//
// Solidity: function pause() returns()
func (_V3Utils *V3UtilsTransactorSession) Pause() (*types.Transaction, error) {
	return _V3Utils.Contract.Pause(&_V3Utils.TransactOpts)
}

// RenounceRole is a paid mutator transaction binding the contract method 0x36568abe.
//
// Solidity: function renounceRole(bytes32 role, address account) returns()
func (_V3Utils *V3UtilsTransactor) RenounceRole(opts *bind.TransactOpts, role [32]byte, account common.Address) (*types.Transaction, error) {
	return _V3Utils.contract.Transact(opts, "renounceRole", role, account)
}

// RenounceRole is a paid mutator transaction binding the contract method 0x36568abe.
//
// Solidity: function renounceRole(bytes32 role, address account) returns()
func (_V3Utils *V3UtilsSession) RenounceRole(role [32]byte, account common.Address) (*types.Transaction, error) {
	return _V3Utils.Contract.RenounceRole(&_V3Utils.TransactOpts, role, account)
}

// RenounceRole is a paid mutator transaction binding the contract method 0x36568abe.
//
// Solidity: function renounceRole(bytes32 role, address account) returns()
func (_V3Utils *V3UtilsTransactorSession) RenounceRole(role [32]byte, account common.Address) (*types.Transaction, error) {
	return _V3Utils.Contract.RenounceRole(&_V3Utils.TransactOpts, role, account)
}

// RevokeRole is a paid mutator transaction binding the contract method 0xd547741f.
//
// Solidity: function revokeRole(bytes32 role, address account) returns()
func (_V3Utils *V3UtilsTransactor) RevokeRole(opts *bind.TransactOpts, role [32]byte, account common.Address) (*types.Transaction, error) {
	return _V3Utils.contract.Transact(opts, "revokeRole", role, account)
}

// RevokeRole is a paid mutator transaction binding the contract method 0xd547741f.
//
// Solidity: function revokeRole(bytes32 role, address account) returns()
func (_V3Utils *V3UtilsSession) RevokeRole(role [32]byte, account common.Address) (*types.Transaction, error) {
	return _V3Utils.Contract.RevokeRole(&_V3Utils.TransactOpts, role, account)
}

// RevokeRole is a paid mutator transaction binding the contract method 0xd547741f.
//
// Solidity: function revokeRole(bytes32 role, address account) returns()
func (_V3Utils *V3UtilsTransactorSession) RevokeRole(role [32]byte, account common.Address) (*types.Transaction, error) {
	return _V3Utils.Contract.RevokeRole(&_V3Utils.TransactOpts, role, account)
}

// SetFeeTaker is a paid mutator transaction binding the contract method 0x4ec5908d.
//
// Solidity: function setFeeTaker(address feeTaker) returns()
func (_V3Utils *V3UtilsTransactor) SetFeeTaker(opts *bind.TransactOpts, feeTaker common.Address) (*types.Transaction, error) {
	return _V3Utils.contract.Transact(opts, "setFeeTaker", feeTaker)
}

// SetFeeTaker is a paid mutator transaction binding the contract method 0x4ec5908d.
//
// Solidity: function setFeeTaker(address feeTaker) returns()
func (_V3Utils *V3UtilsSession) SetFeeTaker(feeTaker common.Address) (*types.Transaction, error) {
	return _V3Utils.Contract.SetFeeTaker(&_V3Utils.TransactOpts, feeTaker)
}

// SetFeeTaker is a paid mutator transaction binding the contract method 0x4ec5908d.
//
// Solidity: function setFeeTaker(address feeTaker) returns()
func (_V3Utils *V3UtilsTransactorSession) SetFeeTaker(feeTaker common.Address) (*types.Transaction, error) {
	return _V3Utils.Contract.SetFeeTaker(&_V3Utils.TransactOpts, feeTaker)
}

// SetMaxFeeX64 is a paid mutator transaction binding the contract method 0xd6ee2b42.
//
// Solidity: function setMaxFeeX64(uint8 feeType, uint64 feex64) returns()
func (_V3Utils *V3UtilsTransactor) SetMaxFeeX64(opts *bind.TransactOpts, feeType uint8, feex64 uint64) (*types.Transaction, error) {
	return _V3Utils.contract.Transact(opts, "setMaxFeeX64", feeType, feex64)
}

// SetMaxFeeX64 is a paid mutator transaction binding the contract method 0xd6ee2b42.
//
// Solidity: function setMaxFeeX64(uint8 feeType, uint64 feex64) returns()
func (_V3Utils *V3UtilsSession) SetMaxFeeX64(feeType uint8, feex64 uint64) (*types.Transaction, error) {
	return _V3Utils.Contract.SetMaxFeeX64(&_V3Utils.TransactOpts, feeType, feex64)
}

// SetMaxFeeX64 is a paid mutator transaction binding the contract method 0xd6ee2b42.
//
// Solidity: function setMaxFeeX64(uint8 feeType, uint64 feex64) returns()
func (_V3Utils *V3UtilsTransactorSession) SetMaxFeeX64(feeType uint8, feex64 uint64) (*types.Transaction, error) {
	return _V3Utils.Contract.SetMaxFeeX64(&_V3Utils.TransactOpts, feeType, feex64)
}

// SetWhitelistNfpm is a paid mutator transaction binding the contract method 0x9155c7c0.
//
// Solidity: function setWhitelistNfpm(address[] nfpms, bool isWhitelist) returns()
func (_V3Utils *V3UtilsTransactor) SetWhitelistNfpm(opts *bind.TransactOpts, nfpms []common.Address, isWhitelist bool) (*types.Transaction, error) {
	return _V3Utils.contract.Transact(opts, "setWhitelistNfpm", nfpms, isWhitelist)
}

// SetWhitelistNfpm is a paid mutator transaction binding the contract method 0x9155c7c0.
//
// Solidity: function setWhitelistNfpm(address[] nfpms, bool isWhitelist) returns()
func (_V3Utils *V3UtilsSession) SetWhitelistNfpm(nfpms []common.Address, isWhitelist bool) (*types.Transaction, error) {
	return _V3Utils.Contract.SetWhitelistNfpm(&_V3Utils.TransactOpts, nfpms, isWhitelist)
}

// SetWhitelistNfpm is a paid mutator transaction binding the contract method 0x9155c7c0.
//
// Solidity: function setWhitelistNfpm(address[] nfpms, bool isWhitelist) returns()
func (_V3Utils *V3UtilsTransactorSession) SetWhitelistNfpm(nfpms []common.Address, isWhitelist bool) (*types.Transaction, error) {
	return _V3Utils.Contract.SetWhitelistNfpm(&_V3Utils.TransactOpts, nfpms, isWhitelist)
}

// Unpause is a paid mutator transaction binding the contract method 0x3f4ba83a.
//
// Solidity: function unpause() returns()
func (_V3Utils *V3UtilsTransactor) Unpause(opts *bind.TransactOpts) (*types.Transaction, error) {
	return _V3Utils.contract.Transact(opts, "unpause")
}

// Unpause is a paid mutator transaction binding the contract method 0x3f4ba83a.
//
// Solidity: function unpause() returns()
func (_V3Utils *V3UtilsSession) Unpause() (*types.Transaction, error) {
	return _V3Utils.Contract.Unpause(&_V3Utils.TransactOpts)
}

// Unpause is a paid mutator transaction binding the contract method 0x3f4ba83a.
//
// Solidity: function unpause() returns()
func (_V3Utils *V3UtilsTransactorSession) Unpause() (*types.Transaction, error) {
	return _V3Utils.Contract.Unpause(&_V3Utils.TransactOpts)
}

// WithdrawERC20 is a paid mutator transaction binding the contract method 0x340ed32a.
//
// Solidity: function withdrawERC20(address[] tokens, address to) returns()
func (_V3Utils *V3UtilsTransactor) WithdrawERC20(opts *bind.TransactOpts, tokens []common.Address, to common.Address) (*types.Transaction, error) {
	return _V3Utils.contract.Transact(opts, "withdrawERC20", tokens, to)
}

// WithdrawERC20 is a paid mutator transaction binding the contract method 0x340ed32a.
//
// Solidity: function withdrawERC20(address[] tokens, address to) returns()
func (_V3Utils *V3UtilsSession) WithdrawERC20(tokens []common.Address, to common.Address) (*types.Transaction, error) {
	return _V3Utils.Contract.WithdrawERC20(&_V3Utils.TransactOpts, tokens, to)
}

// WithdrawERC20 is a paid mutator transaction binding the contract method 0x340ed32a.
//
// Solidity: function withdrawERC20(address[] tokens, address to) returns()
func (_V3Utils *V3UtilsTransactorSession) WithdrawERC20(tokens []common.Address, to common.Address) (*types.Transaction, error) {
	return _V3Utils.Contract.WithdrawERC20(&_V3Utils.TransactOpts, tokens, to)
}

// WithdrawERC721 is a paid mutator transaction binding the contract method 0x7b9f76b5.
//
// Solidity: function withdrawERC721(address nfpm, uint256 tokenId, address to) returns()
func (_V3Utils *V3UtilsTransactor) WithdrawERC721(opts *bind.TransactOpts, nfpm common.Address, tokenId *big.Int, to common.Address) (*types.Transaction, error) {
	return _V3Utils.contract.Transact(opts, "withdrawERC721", nfpm, tokenId, to)
}

// WithdrawERC721 is a paid mutator transaction binding the contract method 0x7b9f76b5.
//
// Solidity: function withdrawERC721(address nfpm, uint256 tokenId, address to) returns()
func (_V3Utils *V3UtilsSession) WithdrawERC721(nfpm common.Address, tokenId *big.Int, to common.Address) (*types.Transaction, error) {
	return _V3Utils.Contract.WithdrawERC721(&_V3Utils.TransactOpts, nfpm, tokenId, to)
}

// WithdrawERC721 is a paid mutator transaction binding the contract method 0x7b9f76b5.
//
// Solidity: function withdrawERC721(address nfpm, uint256 tokenId, address to) returns()
func (_V3Utils *V3UtilsTransactorSession) WithdrawERC721(nfpm common.Address, tokenId *big.Int, to common.Address) (*types.Transaction, error) {
	return _V3Utils.Contract.WithdrawERC721(&_V3Utils.TransactOpts, nfpm, tokenId, to)
}

// WithdrawNative is a paid mutator transaction binding the contract method 0x2f622e6b.
//
// Solidity: function withdrawNative(address to) returns()
func (_V3Utils *V3UtilsTransactor) WithdrawNative(opts *bind.TransactOpts, to common.Address) (*types.Transaction, error) {
	return _V3Utils.contract.Transact(opts, "withdrawNative", to)
}

// WithdrawNative is a paid mutator transaction binding the contract method 0x2f622e6b.
//
// Solidity: function withdrawNative(address to) returns()
func (_V3Utils *V3UtilsSession) WithdrawNative(to common.Address) (*types.Transaction, error) {
	return _V3Utils.Contract.WithdrawNative(&_V3Utils.TransactOpts, to)
}

// WithdrawNative is a paid mutator transaction binding the contract method 0x2f622e6b.
//
// Solidity: function withdrawNative(address to) returns()
func (_V3Utils *V3UtilsTransactorSession) WithdrawNative(to common.Address) (*types.Transaction, error) {
	return _V3Utils.Contract.WithdrawNative(&_V3Utils.TransactOpts, to)
}

// Receive is a paid mutator transaction binding the contract receive function.
//
// Solidity: receive() payable returns()
func (_V3Utils *V3UtilsTransactor) Receive(opts *bind.TransactOpts) (*types.Transaction, error) {
	return _V3Utils.contract.RawTransact(opts, nil) // calldata is disallowed for receive function
}

// Receive is a paid mutator transaction binding the contract receive function.
//
// Solidity: receive() payable returns()
func (_V3Utils *V3UtilsSession) Receive() (*types.Transaction, error) {
	return _V3Utils.Contract.Receive(&_V3Utils.TransactOpts)
}

// Receive is a paid mutator transaction binding the contract receive function.
//
// Solidity: receive() payable returns()
func (_V3Utils *V3UtilsTransactorSession) Receive() (*types.Transaction, error) {
	return _V3Utils.Contract.Receive(&_V3Utils.TransactOpts)
}

// V3UtilsCancelOrderIterator is returned from FilterCancelOrder and is used to iterate over the raw logs and unpacked data for CancelOrder events raised by the V3Utils contract.
type V3UtilsCancelOrderIterator struct {
	Event *V3UtilsCancelOrder // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *V3UtilsCancelOrderIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(V3UtilsCancelOrder)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(V3UtilsCancelOrder)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *V3UtilsCancelOrderIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *V3UtilsCancelOrderIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// V3UtilsCancelOrder represents a CancelOrder event raised by the V3Utils contract.
type V3UtilsCancelOrder struct {
	User      common.Address
	Order     []byte
	Signature []byte
	Raw       types.Log // Blockchain specific contextual infos
}

// FilterCancelOrder is a free log retrieval operation binding the contract event 0x8597445d3e6c82486d8657058b6a42c243329976f148ddd5bede214e979ada96.
//
// Solidity: event CancelOrder(address user, bytes order, bytes signature)
func (_V3Utils *V3UtilsFilterer) FilterCancelOrder(opts *bind.FilterOpts) (*V3UtilsCancelOrderIterator, error) {

	logs, sub, err := _V3Utils.contract.FilterLogs(opts, "CancelOrder")
	if err != nil {
		return nil, err
	}
	return &V3UtilsCancelOrderIterator{contract: _V3Utils.contract, event: "CancelOrder", logs: logs, sub: sub}, nil
}

// WatchCancelOrder is a free log subscription operation binding the contract event 0x8597445d3e6c82486d8657058b6a42c243329976f148ddd5bede214e979ada96.
//
// Solidity: event CancelOrder(address user, bytes order, bytes signature)
func (_V3Utils *V3UtilsFilterer) WatchCancelOrder(opts *bind.WatchOpts, sink chan<- *V3UtilsCancelOrder) (event.Subscription, error) {

	logs, sub, err := _V3Utils.contract.WatchLogs(opts, "CancelOrder")
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(V3UtilsCancelOrder)
				if err := _V3Utils.contract.UnpackLog(event, "CancelOrder", log); err != nil {
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseCancelOrder is a log parse operation binding the contract event 0x8597445d3e6c82486d8657058b6a42c243329976f148ddd5bede214e979ada96.
//
// Solidity: event CancelOrder(address user, bytes order, bytes signature)
func (_V3Utils *V3UtilsFilterer) ParseCancelOrder(log types.Log) (*V3UtilsCancelOrder, error) {
	event := new(V3UtilsCancelOrder)
	if err := _V3Utils.contract.UnpackLog(event, "CancelOrder", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// V3UtilsChangeRangeIterator is returned from FilterChangeRange and is used to iterate over the raw logs and unpacked data for ChangeRange events raised by the V3Utils contract.
type V3UtilsChangeRangeIterator struct {
	Event *V3UtilsChangeRange // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *V3UtilsChangeRangeIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(V3UtilsChangeRange)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(V3UtilsChangeRange)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *V3UtilsChangeRangeIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *V3UtilsChangeRangeIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// V3UtilsChangeRange represents a ChangeRange event raised by the V3Utils contract.
type V3UtilsChangeRange struct {
	Nfpm         common.Address
	TokenId      *big.Int
	NewTokenId   *big.Int
	NewLiquidity *big.Int
	Token0Added  *big.Int
	Token1Added  *big.Int
	Raw          types.Log // Blockchain specific contextual infos
}

// FilterChangeRange is a free log retrieval operation binding the contract event 0xe878b7324da2e10eb701c2cf0474248cdf5c088bb68aaf3045a6c15d1008b12d.
//
// Solidity: event ChangeRange(address indexed nfpm, uint256 indexed tokenId, uint256 newTokenId, uint256 newLiquidity, uint256 token0Added, uint256 token1Added)
func (_V3Utils *V3UtilsFilterer) FilterChangeRange(opts *bind.FilterOpts, nfpm []common.Address, tokenId []*big.Int) (*V3UtilsChangeRangeIterator, error) {

	var nfpmRule []interface{}
	for _, nfpmItem := range nfpm {
		nfpmRule = append(nfpmRule, nfpmItem)
	}
	var tokenIdRule []interface{}
	for _, tokenIdItem := range tokenId {
		tokenIdRule = append(tokenIdRule, tokenIdItem)
	}

	logs, sub, err := _V3Utils.contract.FilterLogs(opts, "ChangeRange", nfpmRule, tokenIdRule)
	if err != nil {
		return nil, err
	}
	return &V3UtilsChangeRangeIterator{contract: _V3Utils.contract, event: "ChangeRange", logs: logs, sub: sub}, nil
}

// WatchChangeRange is a free log subscription operation binding the contract event 0xe878b7324da2e10eb701c2cf0474248cdf5c088bb68aaf3045a6c15d1008b12d.
//
// Solidity: event ChangeRange(address indexed nfpm, uint256 indexed tokenId, uint256 newTokenId, uint256 newLiquidity, uint256 token0Added, uint256 token1Added)
func (_V3Utils *V3UtilsFilterer) WatchChangeRange(opts *bind.WatchOpts, sink chan<- *V3UtilsChangeRange, nfpm []common.Address, tokenId []*big.Int) (event.Subscription, error) {

	var nfpmRule []interface{}
	for _, nfpmItem := range nfpm {
		nfpmRule = append(nfpmRule, nfpmItem)
	}
	var tokenIdRule []interface{}
	for _, tokenIdItem := range tokenId {
		tokenIdRule = append(tokenIdRule, tokenIdItem)
	}

	logs, sub, err := _V3Utils.contract.WatchLogs(opts, "ChangeRange", nfpmRule, tokenIdRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(V3UtilsChangeRange)
				if err := _V3Utils.contract.UnpackLog(event, "ChangeRange", log); err != nil {
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseChangeRange is a log parse operation binding the contract event 0xe878b7324da2e10eb701c2cf0474248cdf5c088bb68aaf3045a6c15d1008b12d.
//
// Solidity: event ChangeRange(address indexed nfpm, uint256 indexed tokenId, uint256 newTokenId, uint256 newLiquidity, uint256 token0Added, uint256 token1Added)
func (_V3Utils *V3UtilsFilterer) ParseChangeRange(log types.Log) (*V3UtilsChangeRange, error) {
	event := new(V3UtilsChangeRange)
	if err := _V3Utils.contract.UnpackLog(event, "ChangeRange", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// V3UtilsCompoundFeesIterator is returned from FilterCompoundFees and is used to iterate over the raw logs and unpacked data for CompoundFees events raised by the V3Utils contract.
type V3UtilsCompoundFeesIterator struct {
	Event *V3UtilsCompoundFees // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *V3UtilsCompoundFeesIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(V3UtilsCompoundFees)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(V3UtilsCompoundFees)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *V3UtilsCompoundFeesIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *V3UtilsCompoundFeesIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// V3UtilsCompoundFees represents a CompoundFees event raised by the V3Utils contract.
type V3UtilsCompoundFees struct {
	Nfpm      common.Address
	TokenId   *big.Int
	Liquidity *big.Int
	Amount0   *big.Int
	Amount1   *big.Int
	Raw       types.Log // Blockchain specific contextual infos
}

// FilterCompoundFees is a free log retrieval operation binding the contract event 0x4a3d983c4891bedb0622c5a26f90b626e9451fe3a832b73ed9c886f1aa489cda.
//
// Solidity: event CompoundFees(address indexed nfpm, uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
func (_V3Utils *V3UtilsFilterer) FilterCompoundFees(opts *bind.FilterOpts, nfpm []common.Address, tokenId []*big.Int) (*V3UtilsCompoundFeesIterator, error) {

	var nfpmRule []interface{}
	for _, nfpmItem := range nfpm {
		nfpmRule = append(nfpmRule, nfpmItem)
	}
	var tokenIdRule []interface{}
	for _, tokenIdItem := range tokenId {
		tokenIdRule = append(tokenIdRule, tokenIdItem)
	}

	logs, sub, err := _V3Utils.contract.FilterLogs(opts, "CompoundFees", nfpmRule, tokenIdRule)
	if err != nil {
		return nil, err
	}
	return &V3UtilsCompoundFeesIterator{contract: _V3Utils.contract, event: "CompoundFees", logs: logs, sub: sub}, nil
}

// WatchCompoundFees is a free log subscription operation binding the contract event 0x4a3d983c4891bedb0622c5a26f90b626e9451fe3a832b73ed9c886f1aa489cda.
//
// Solidity: event CompoundFees(address indexed nfpm, uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
func (_V3Utils *V3UtilsFilterer) WatchCompoundFees(opts *bind.WatchOpts, sink chan<- *V3UtilsCompoundFees, nfpm []common.Address, tokenId []*big.Int) (event.Subscription, error) {

	var nfpmRule []interface{}
	for _, nfpmItem := range nfpm {
		nfpmRule = append(nfpmRule, nfpmItem)
	}
	var tokenIdRule []interface{}
	for _, tokenIdItem := range tokenId {
		tokenIdRule = append(tokenIdRule, tokenIdItem)
	}

	logs, sub, err := _V3Utils.contract.WatchLogs(opts, "CompoundFees", nfpmRule, tokenIdRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(V3UtilsCompoundFees)
				if err := _V3Utils.contract.UnpackLog(event, "CompoundFees", log); err != nil {
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseCompoundFees is a log parse operation binding the contract event 0x4a3d983c4891bedb0622c5a26f90b626e9451fe3a832b73ed9c886f1aa489cda.
//
// Solidity: event CompoundFees(address indexed nfpm, uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
func (_V3Utils *V3UtilsFilterer) ParseCompoundFees(log types.Log) (*V3UtilsCompoundFees, error) {
	event := new(V3UtilsCompoundFees)
	if err := _V3Utils.contract.UnpackLog(event, "CompoundFees", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// V3UtilsDeductFeesIterator is returned from FilterDeductFees and is used to iterate over the raw logs and unpacked data for DeductFees events raised by the V3Utils contract.
type V3UtilsDeductFeesIterator struct {
	Event *V3UtilsDeductFees // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *V3UtilsDeductFeesIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(V3UtilsDeductFees)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(V3UtilsDeductFees)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *V3UtilsDeductFeesIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *V3UtilsDeductFeesIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// V3UtilsDeductFees represents a DeductFees event raised by the V3Utils contract.
type V3UtilsDeductFees struct {
	Nfpm        common.Address
	TokenId     *big.Int
	UserAddress common.Address
	Data        CommonDeductFeesEventData
	Raw         types.Log // Blockchain specific contextual infos
}

// FilterDeductFees is a free log retrieval operation binding the contract event 0x07b9ff32d43e39b450a13b642c1e93282a8ea460336f1422bddc6164b304c2da.
//
// Solidity: event DeductFees(address indexed nfpm, uint256 indexed tokenId, address indexed userAddress, (address,address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint64,uint8) data)
func (_V3Utils *V3UtilsFilterer) FilterDeductFees(opts *bind.FilterOpts, nfpm []common.Address, tokenId []*big.Int, userAddress []common.Address) (*V3UtilsDeductFeesIterator, error) {

	var nfpmRule []interface{}
	for _, nfpmItem := range nfpm {
		nfpmRule = append(nfpmRule, nfpmItem)
	}
	var tokenIdRule []interface{}
	for _, tokenIdItem := range tokenId {
		tokenIdRule = append(tokenIdRule, tokenIdItem)
	}
	var userAddressRule []interface{}
	for _, userAddressItem := range userAddress {
		userAddressRule = append(userAddressRule, userAddressItem)
	}

	logs, sub, err := _V3Utils.contract.FilterLogs(opts, "DeductFees", nfpmRule, tokenIdRule, userAddressRule)
	if err != nil {
		return nil, err
	}
	return &V3UtilsDeductFeesIterator{contract: _V3Utils.contract, event: "DeductFees", logs: logs, sub: sub}, nil
}

// WatchDeductFees is a free log subscription operation binding the contract event 0x07b9ff32d43e39b450a13b642c1e93282a8ea460336f1422bddc6164b304c2da.
//
// Solidity: event DeductFees(address indexed nfpm, uint256 indexed tokenId, address indexed userAddress, (address,address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint64,uint8) data)
func (_V3Utils *V3UtilsFilterer) WatchDeductFees(opts *bind.WatchOpts, sink chan<- *V3UtilsDeductFees, nfpm []common.Address, tokenId []*big.Int, userAddress []common.Address) (event.Subscription, error) {

	var nfpmRule []interface{}
	for _, nfpmItem := range nfpm {
		nfpmRule = append(nfpmRule, nfpmItem)
	}
	var tokenIdRule []interface{}
	for _, tokenIdItem := range tokenId {
		tokenIdRule = append(tokenIdRule, tokenIdItem)
	}
	var userAddressRule []interface{}
	for _, userAddressItem := range userAddress {
		userAddressRule = append(userAddressRule, userAddressItem)
	}

	logs, sub, err := _V3Utils.contract.WatchLogs(opts, "DeductFees", nfpmRule, tokenIdRule, userAddressRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(V3UtilsDeductFees)
				if err := _V3Utils.contract.UnpackLog(event, "DeductFees", log); err != nil {
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseDeductFees is a log parse operation binding the contract event 0x07b9ff32d43e39b450a13b642c1e93282a8ea460336f1422bddc6164b304c2da.
//
// Solidity: event DeductFees(address indexed nfpm, uint256 indexed tokenId, address indexed userAddress, (address,address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint64,uint8) data)
func (_V3Utils *V3UtilsFilterer) ParseDeductFees(log types.Log) (*V3UtilsDeductFees, error) {
	event := new(V3UtilsDeductFees)
	if err := _V3Utils.contract.UnpackLog(event, "DeductFees", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// V3UtilsPausedIterator is returned from FilterPaused and is used to iterate over the raw logs and unpacked data for Paused events raised by the V3Utils contract.
type V3UtilsPausedIterator struct {
	Event *V3UtilsPaused // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *V3UtilsPausedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(V3UtilsPaused)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(V3UtilsPaused)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *V3UtilsPausedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *V3UtilsPausedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// V3UtilsPaused represents a Paused event raised by the V3Utils contract.
type V3UtilsPaused struct {
	Account common.Address
	Raw     types.Log // Blockchain specific contextual infos
}

// FilterPaused is a free log retrieval operation binding the contract event 0x62e78cea01bee320cd4e420270b5ea74000d11b0c9f74754ebdbfc544b05a258.
//
// Solidity: event Paused(address account)
func (_V3Utils *V3UtilsFilterer) FilterPaused(opts *bind.FilterOpts) (*V3UtilsPausedIterator, error) {

	logs, sub, err := _V3Utils.contract.FilterLogs(opts, "Paused")
	if err != nil {
		return nil, err
	}
	return &V3UtilsPausedIterator{contract: _V3Utils.contract, event: "Paused", logs: logs, sub: sub}, nil
}

// WatchPaused is a free log subscription operation binding the contract event 0x62e78cea01bee320cd4e420270b5ea74000d11b0c9f74754ebdbfc544b05a258.
//
// Solidity: event Paused(address account)
func (_V3Utils *V3UtilsFilterer) WatchPaused(opts *bind.WatchOpts, sink chan<- *V3UtilsPaused) (event.Subscription, error) {

	logs, sub, err := _V3Utils.contract.WatchLogs(opts, "Paused")
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(V3UtilsPaused)
				if err := _V3Utils.contract.UnpackLog(event, "Paused", log); err != nil {
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParsePaused is a log parse operation binding the contract event 0x62e78cea01bee320cd4e420270b5ea74000d11b0c9f74754ebdbfc544b05a258.
//
// Solidity: event Paused(address account)
func (_V3Utils *V3UtilsFilterer) ParsePaused(log types.Log) (*V3UtilsPaused, error) {
	event := new(V3UtilsPaused)
	if err := _V3Utils.contract.UnpackLog(event, "Paused", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// V3UtilsRoleAdminChangedIterator is returned from FilterRoleAdminChanged and is used to iterate over the raw logs and unpacked data for RoleAdminChanged events raised by the V3Utils contract.
type V3UtilsRoleAdminChangedIterator struct {
	Event *V3UtilsRoleAdminChanged // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *V3UtilsRoleAdminChangedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(V3UtilsRoleAdminChanged)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(V3UtilsRoleAdminChanged)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *V3UtilsRoleAdminChangedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *V3UtilsRoleAdminChangedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// V3UtilsRoleAdminChanged represents a RoleAdminChanged event raised by the V3Utils contract.
type V3UtilsRoleAdminChanged struct {
	Role              [32]byte
	PreviousAdminRole [32]byte
	NewAdminRole      [32]byte
	Raw               types.Log // Blockchain specific contextual infos
}

// FilterRoleAdminChanged is a free log retrieval operation binding the contract event 0xbd79b86ffe0ab8e8776151514217cd7cacd52c909f66475c3af44e129f0b00ff.
//
// Solidity: event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole)
func (_V3Utils *V3UtilsFilterer) FilterRoleAdminChanged(opts *bind.FilterOpts, role [][32]byte, previousAdminRole [][32]byte, newAdminRole [][32]byte) (*V3UtilsRoleAdminChangedIterator, error) {

	var roleRule []interface{}
	for _, roleItem := range role {
		roleRule = append(roleRule, roleItem)
	}
	var previousAdminRoleRule []interface{}
	for _, previousAdminRoleItem := range previousAdminRole {
		previousAdminRoleRule = append(previousAdminRoleRule, previousAdminRoleItem)
	}
	var newAdminRoleRule []interface{}
	for _, newAdminRoleItem := range newAdminRole {
		newAdminRoleRule = append(newAdminRoleRule, newAdminRoleItem)
	}

	logs, sub, err := _V3Utils.contract.FilterLogs(opts, "RoleAdminChanged", roleRule, previousAdminRoleRule, newAdminRoleRule)
	if err != nil {
		return nil, err
	}
	return &V3UtilsRoleAdminChangedIterator{contract: _V3Utils.contract, event: "RoleAdminChanged", logs: logs, sub: sub}, nil
}

// WatchRoleAdminChanged is a free log subscription operation binding the contract event 0xbd79b86ffe0ab8e8776151514217cd7cacd52c909f66475c3af44e129f0b00ff.
//
// Solidity: event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole)
func (_V3Utils *V3UtilsFilterer) WatchRoleAdminChanged(opts *bind.WatchOpts, sink chan<- *V3UtilsRoleAdminChanged, role [][32]byte, previousAdminRole [][32]byte, newAdminRole [][32]byte) (event.Subscription, error) {

	var roleRule []interface{}
	for _, roleItem := range role {
		roleRule = append(roleRule, roleItem)
	}
	var previousAdminRoleRule []interface{}
	for _, previousAdminRoleItem := range previousAdminRole {
		previousAdminRoleRule = append(previousAdminRoleRule, previousAdminRoleItem)
	}
	var newAdminRoleRule []interface{}
	for _, newAdminRoleItem := range newAdminRole {
		newAdminRoleRule = append(newAdminRoleRule, newAdminRoleItem)
	}

	logs, sub, err := _V3Utils.contract.WatchLogs(opts, "RoleAdminChanged", roleRule, previousAdminRoleRule, newAdminRoleRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(V3UtilsRoleAdminChanged)
				if err := _V3Utils.contract.UnpackLog(event, "RoleAdminChanged", log); err != nil {
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseRoleAdminChanged is a log parse operation binding the contract event 0xbd79b86ffe0ab8e8776151514217cd7cacd52c909f66475c3af44e129f0b00ff.
//
// Solidity: event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole)
func (_V3Utils *V3UtilsFilterer) ParseRoleAdminChanged(log types.Log) (*V3UtilsRoleAdminChanged, error) {
	event := new(V3UtilsRoleAdminChanged)
	if err := _V3Utils.contract.UnpackLog(event, "RoleAdminChanged", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// V3UtilsRoleGrantedIterator is returned from FilterRoleGranted and is used to iterate over the raw logs and unpacked data for RoleGranted events raised by the V3Utils contract.
type V3UtilsRoleGrantedIterator struct {
	Event *V3UtilsRoleGranted // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *V3UtilsRoleGrantedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(V3UtilsRoleGranted)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(V3UtilsRoleGranted)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *V3UtilsRoleGrantedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *V3UtilsRoleGrantedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// V3UtilsRoleGranted represents a RoleGranted event raised by the V3Utils contract.
type V3UtilsRoleGranted struct {
	Role    [32]byte
	Account common.Address
	Sender  common.Address
	Raw     types.Log // Blockchain specific contextual infos
}

// FilterRoleGranted is a free log retrieval operation binding the contract event 0x2f8788117e7eff1d82e926ec794901d17c78024a50270940304540a733656f0d.
//
// Solidity: event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender)
func (_V3Utils *V3UtilsFilterer) FilterRoleGranted(opts *bind.FilterOpts, role [][32]byte, account []common.Address, sender []common.Address) (*V3UtilsRoleGrantedIterator, error) {

	var roleRule []interface{}
	for _, roleItem := range role {
		roleRule = append(roleRule, roleItem)
	}
	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}
	var senderRule []interface{}
	for _, senderItem := range sender {
		senderRule = append(senderRule, senderItem)
	}

	logs, sub, err := _V3Utils.contract.FilterLogs(opts, "RoleGranted", roleRule, accountRule, senderRule)
	if err != nil {
		return nil, err
	}
	return &V3UtilsRoleGrantedIterator{contract: _V3Utils.contract, event: "RoleGranted", logs: logs, sub: sub}, nil
}

// WatchRoleGranted is a free log subscription operation binding the contract event 0x2f8788117e7eff1d82e926ec794901d17c78024a50270940304540a733656f0d.
//
// Solidity: event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender)
func (_V3Utils *V3UtilsFilterer) WatchRoleGranted(opts *bind.WatchOpts, sink chan<- *V3UtilsRoleGranted, role [][32]byte, account []common.Address, sender []common.Address) (event.Subscription, error) {

	var roleRule []interface{}
	for _, roleItem := range role {
		roleRule = append(roleRule, roleItem)
	}
	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}
	var senderRule []interface{}
	for _, senderItem := range sender {
		senderRule = append(senderRule, senderItem)
	}

	logs, sub, err := _V3Utils.contract.WatchLogs(opts, "RoleGranted", roleRule, accountRule, senderRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(V3UtilsRoleGranted)
				if err := _V3Utils.contract.UnpackLog(event, "RoleGranted", log); err != nil {
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseRoleGranted is a log parse operation binding the contract event 0x2f8788117e7eff1d82e926ec794901d17c78024a50270940304540a733656f0d.
//
// Solidity: event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender)
func (_V3Utils *V3UtilsFilterer) ParseRoleGranted(log types.Log) (*V3UtilsRoleGranted, error) {
	event := new(V3UtilsRoleGranted)
	if err := _V3Utils.contract.UnpackLog(event, "RoleGranted", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// V3UtilsRoleRevokedIterator is returned from FilterRoleRevoked and is used to iterate over the raw logs and unpacked data for RoleRevoked events raised by the V3Utils contract.
type V3UtilsRoleRevokedIterator struct {
	Event *V3UtilsRoleRevoked // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *V3UtilsRoleRevokedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(V3UtilsRoleRevoked)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(V3UtilsRoleRevoked)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *V3UtilsRoleRevokedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *V3UtilsRoleRevokedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// V3UtilsRoleRevoked represents a RoleRevoked event raised by the V3Utils contract.
type V3UtilsRoleRevoked struct {
	Role    [32]byte
	Account common.Address
	Sender  common.Address
	Raw     types.Log // Blockchain specific contextual infos
}

// FilterRoleRevoked is a free log retrieval operation binding the contract event 0xf6391f5c32d9c69d2a47ea670b442974b53935d1edc7fd64eb21e047a839171b.
//
// Solidity: event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender)
func (_V3Utils *V3UtilsFilterer) FilterRoleRevoked(opts *bind.FilterOpts, role [][32]byte, account []common.Address, sender []common.Address) (*V3UtilsRoleRevokedIterator, error) {

	var roleRule []interface{}
	for _, roleItem := range role {
		roleRule = append(roleRule, roleItem)
	}
	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}
	var senderRule []interface{}
	for _, senderItem := range sender {
		senderRule = append(senderRule, senderItem)
	}

	logs, sub, err := _V3Utils.contract.FilterLogs(opts, "RoleRevoked", roleRule, accountRule, senderRule)
	if err != nil {
		return nil, err
	}
	return &V3UtilsRoleRevokedIterator{contract: _V3Utils.contract, event: "RoleRevoked", logs: logs, sub: sub}, nil
}

// WatchRoleRevoked is a free log subscription operation binding the contract event 0xf6391f5c32d9c69d2a47ea670b442974b53935d1edc7fd64eb21e047a839171b.
//
// Solidity: event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender)
func (_V3Utils *V3UtilsFilterer) WatchRoleRevoked(opts *bind.WatchOpts, sink chan<- *V3UtilsRoleRevoked, role [][32]byte, account []common.Address, sender []common.Address) (event.Subscription, error) {

	var roleRule []interface{}
	for _, roleItem := range role {
		roleRule = append(roleRule, roleItem)
	}
	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}
	var senderRule []interface{}
	for _, senderItem := range sender {
		senderRule = append(senderRule, senderItem)
	}

	logs, sub, err := _V3Utils.contract.WatchLogs(opts, "RoleRevoked", roleRule, accountRule, senderRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(V3UtilsRoleRevoked)
				if err := _V3Utils.contract.UnpackLog(event, "RoleRevoked", log); err != nil {
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseRoleRevoked is a log parse operation binding the contract event 0xf6391f5c32d9c69d2a47ea670b442974b53935d1edc7fd64eb21e047a839171b.
//
// Solidity: event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender)
func (_V3Utils *V3UtilsFilterer) ParseRoleRevoked(log types.Log) (*V3UtilsRoleRevoked, error) {
	event := new(V3UtilsRoleRevoked)
	if err := _V3Utils.contract.UnpackLog(event, "RoleRevoked", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// V3UtilsSwapIterator is returned from FilterSwap and is used to iterate over the raw logs and unpacked data for Swap events raised by the V3Utils contract.
type V3UtilsSwapIterator struct {
	Event *V3UtilsSwap // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *V3UtilsSwapIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(V3UtilsSwap)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(V3UtilsSwap)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *V3UtilsSwapIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *V3UtilsSwapIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// V3UtilsSwap represents a Swap event raised by the V3Utils contract.
type V3UtilsSwap struct {
	TokenIn   common.Address
	TokenOut  common.Address
	AmountIn  *big.Int
	AmountOut *big.Int
	Raw       types.Log // Blockchain specific contextual infos
}

// FilterSwap is a free log retrieval operation binding the contract event 0xfa2dda1cc1b86e41239702756b13effbc1a092b5c57e3ad320fbe4f3b13fe235.
//
// Solidity: event Swap(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut)
func (_V3Utils *V3UtilsFilterer) FilterSwap(opts *bind.FilterOpts, tokenIn []common.Address, tokenOut []common.Address) (*V3UtilsSwapIterator, error) {

	var tokenInRule []interface{}
	for _, tokenInItem := range tokenIn {
		tokenInRule = append(tokenInRule, tokenInItem)
	}
	var tokenOutRule []interface{}
	for _, tokenOutItem := range tokenOut {
		tokenOutRule = append(tokenOutRule, tokenOutItem)
	}

	logs, sub, err := _V3Utils.contract.FilterLogs(opts, "Swap", tokenInRule, tokenOutRule)
	if err != nil {
		return nil, err
	}
	return &V3UtilsSwapIterator{contract: _V3Utils.contract, event: "Swap", logs: logs, sub: sub}, nil
}

// WatchSwap is a free log subscription operation binding the contract event 0xfa2dda1cc1b86e41239702756b13effbc1a092b5c57e3ad320fbe4f3b13fe235.
//
// Solidity: event Swap(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut)
func (_V3Utils *V3UtilsFilterer) WatchSwap(opts *bind.WatchOpts, sink chan<- *V3UtilsSwap, tokenIn []common.Address, tokenOut []common.Address) (event.Subscription, error) {

	var tokenInRule []interface{}
	for _, tokenInItem := range tokenIn {
		tokenInRule = append(tokenInRule, tokenInItem)
	}
	var tokenOutRule []interface{}
	for _, tokenOutItem := range tokenOut {
		tokenOutRule = append(tokenOutRule, tokenOutItem)
	}

	logs, sub, err := _V3Utils.contract.WatchLogs(opts, "Swap", tokenInRule, tokenOutRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(V3UtilsSwap)
				if err := _V3Utils.contract.UnpackLog(event, "Swap", log); err != nil {
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseSwap is a log parse operation binding the contract event 0xfa2dda1cc1b86e41239702756b13effbc1a092b5c57e3ad320fbe4f3b13fe235.
//
// Solidity: event Swap(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut)
func (_V3Utils *V3UtilsFilterer) ParseSwap(log types.Log) (*V3UtilsSwap, error) {
	event := new(V3UtilsSwap)
	if err := _V3Utils.contract.UnpackLog(event, "Swap", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// V3UtilsSwapAndIncreaseLiquidityIterator is returned from FilterSwapAndIncreaseLiquidity and is used to iterate over the raw logs and unpacked data for SwapAndIncreaseLiquidity events raised by the V3Utils contract.
type V3UtilsSwapAndIncreaseLiquidityIterator struct {
	Event *V3UtilsSwapAndIncreaseLiquidity // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *V3UtilsSwapAndIncreaseLiquidityIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(V3UtilsSwapAndIncreaseLiquidity)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(V3UtilsSwapAndIncreaseLiquidity)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *V3UtilsSwapAndIncreaseLiquidityIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *V3UtilsSwapAndIncreaseLiquidityIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// V3UtilsSwapAndIncreaseLiquidity represents a SwapAndIncreaseLiquidity event raised by the V3Utils contract.
type V3UtilsSwapAndIncreaseLiquidity struct {
	Nfpm      common.Address
	TokenId   *big.Int
	Liquidity *big.Int
	Amount0   *big.Int
	Amount1   *big.Int
	Raw       types.Log // Blockchain specific contextual infos
}

// FilterSwapAndIncreaseLiquidity is a free log retrieval operation binding the contract event 0xe96b62a2783f0eb40eb1daf87ed80a62c56c56e33c3669bf7f1ce575bd5d81ac.
//
// Solidity: event SwapAndIncreaseLiquidity(address indexed nfpm, uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
func (_V3Utils *V3UtilsFilterer) FilterSwapAndIncreaseLiquidity(opts *bind.FilterOpts, nfpm []common.Address, tokenId []*big.Int) (*V3UtilsSwapAndIncreaseLiquidityIterator, error) {

	var nfpmRule []interface{}
	for _, nfpmItem := range nfpm {
		nfpmRule = append(nfpmRule, nfpmItem)
	}
	var tokenIdRule []interface{}
	for _, tokenIdItem := range tokenId {
		tokenIdRule = append(tokenIdRule, tokenIdItem)
	}

	logs, sub, err := _V3Utils.contract.FilterLogs(opts, "SwapAndIncreaseLiquidity", nfpmRule, tokenIdRule)
	if err != nil {
		return nil, err
	}
	return &V3UtilsSwapAndIncreaseLiquidityIterator{contract: _V3Utils.contract, event: "SwapAndIncreaseLiquidity", logs: logs, sub: sub}, nil
}

// WatchSwapAndIncreaseLiquidity is a free log subscription operation binding the contract event 0xe96b62a2783f0eb40eb1daf87ed80a62c56c56e33c3669bf7f1ce575bd5d81ac.
//
// Solidity: event SwapAndIncreaseLiquidity(address indexed nfpm, uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
func (_V3Utils *V3UtilsFilterer) WatchSwapAndIncreaseLiquidity(opts *bind.WatchOpts, sink chan<- *V3UtilsSwapAndIncreaseLiquidity, nfpm []common.Address, tokenId []*big.Int) (event.Subscription, error) {

	var nfpmRule []interface{}
	for _, nfpmItem := range nfpm {
		nfpmRule = append(nfpmRule, nfpmItem)
	}
	var tokenIdRule []interface{}
	for _, tokenIdItem := range tokenId {
		tokenIdRule = append(tokenIdRule, tokenIdItem)
	}

	logs, sub, err := _V3Utils.contract.WatchLogs(opts, "SwapAndIncreaseLiquidity", nfpmRule, tokenIdRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(V3UtilsSwapAndIncreaseLiquidity)
				if err := _V3Utils.contract.UnpackLog(event, "SwapAndIncreaseLiquidity", log); err != nil {
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseSwapAndIncreaseLiquidity is a log parse operation binding the contract event 0xe96b62a2783f0eb40eb1daf87ed80a62c56c56e33c3669bf7f1ce575bd5d81ac.
//
// Solidity: event SwapAndIncreaseLiquidity(address indexed nfpm, uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
func (_V3Utils *V3UtilsFilterer) ParseSwapAndIncreaseLiquidity(log types.Log) (*V3UtilsSwapAndIncreaseLiquidity, error) {
	event := new(V3UtilsSwapAndIncreaseLiquidity)
	if err := _V3Utils.contract.UnpackLog(event, "SwapAndIncreaseLiquidity", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// V3UtilsSwapAndMintIterator is returned from FilterSwapAndMint and is used to iterate over the raw logs and unpacked data for SwapAndMint events raised by the V3Utils contract.
type V3UtilsSwapAndMintIterator struct {
	Event *V3UtilsSwapAndMint // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *V3UtilsSwapAndMintIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(V3UtilsSwapAndMint)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(V3UtilsSwapAndMint)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *V3UtilsSwapAndMintIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *V3UtilsSwapAndMintIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// V3UtilsSwapAndMint represents a SwapAndMint event raised by the V3Utils contract.
type V3UtilsSwapAndMint struct {
	Nfpm      common.Address
	TokenId   *big.Int
	Liquidity *big.Int
	Amount0   *big.Int
	Amount1   *big.Int
	Raw       types.Log // Blockchain specific contextual infos
}

// FilterSwapAndMint is a free log retrieval operation binding the contract event 0xa9c03b58d729c750f50b2c6854d5db412e7faa78156e5ddf9225285e19011ff7.
//
// Solidity: event SwapAndMint(address indexed nfpm, uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
func (_V3Utils *V3UtilsFilterer) FilterSwapAndMint(opts *bind.FilterOpts, nfpm []common.Address, tokenId []*big.Int) (*V3UtilsSwapAndMintIterator, error) {

	var nfpmRule []interface{}
	for _, nfpmItem := range nfpm {
		nfpmRule = append(nfpmRule, nfpmItem)
	}
	var tokenIdRule []interface{}
	for _, tokenIdItem := range tokenId {
		tokenIdRule = append(tokenIdRule, tokenIdItem)
	}

	logs, sub, err := _V3Utils.contract.FilterLogs(opts, "SwapAndMint", nfpmRule, tokenIdRule)
	if err != nil {
		return nil, err
	}
	return &V3UtilsSwapAndMintIterator{contract: _V3Utils.contract, event: "SwapAndMint", logs: logs, sub: sub}, nil
}

// WatchSwapAndMint is a free log subscription operation binding the contract event 0xa9c03b58d729c750f50b2c6854d5db412e7faa78156e5ddf9225285e19011ff7.
//
// Solidity: event SwapAndMint(address indexed nfpm, uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
func (_V3Utils *V3UtilsFilterer) WatchSwapAndMint(opts *bind.WatchOpts, sink chan<- *V3UtilsSwapAndMint, nfpm []common.Address, tokenId []*big.Int) (event.Subscription, error) {

	var nfpmRule []interface{}
	for _, nfpmItem := range nfpm {
		nfpmRule = append(nfpmRule, nfpmItem)
	}
	var tokenIdRule []interface{}
	for _, tokenIdItem := range tokenId {
		tokenIdRule = append(tokenIdRule, tokenIdItem)
	}

	logs, sub, err := _V3Utils.contract.WatchLogs(opts, "SwapAndMint", nfpmRule, tokenIdRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(V3UtilsSwapAndMint)
				if err := _V3Utils.contract.UnpackLog(event, "SwapAndMint", log); err != nil {
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseSwapAndMint is a log parse operation binding the contract event 0xa9c03b58d729c750f50b2c6854d5db412e7faa78156e5ddf9225285e19011ff7.
//
// Solidity: event SwapAndMint(address indexed nfpm, uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
func (_V3Utils *V3UtilsFilterer) ParseSwapAndMint(log types.Log) (*V3UtilsSwapAndMint, error) {
	event := new(V3UtilsSwapAndMint)
	if err := _V3Utils.contract.UnpackLog(event, "SwapAndMint", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// V3UtilsUnpausedIterator is returned from FilterUnpaused and is used to iterate over the raw logs and unpacked data for Unpaused events raised by the V3Utils contract.
type V3UtilsUnpausedIterator struct {
	Event *V3UtilsUnpaused // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *V3UtilsUnpausedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(V3UtilsUnpaused)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(V3UtilsUnpaused)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *V3UtilsUnpausedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *V3UtilsUnpausedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// V3UtilsUnpaused represents a Unpaused event raised by the V3Utils contract.
type V3UtilsUnpaused struct {
	Account common.Address
	Raw     types.Log // Blockchain specific contextual infos
}

// FilterUnpaused is a free log retrieval operation binding the contract event 0x5db9ee0a495bf2e6ff9c91a7834c1ba4fdd244a5e8aa4e537bd38aeae4b073aa.
//
// Solidity: event Unpaused(address account)
func (_V3Utils *V3UtilsFilterer) FilterUnpaused(opts *bind.FilterOpts) (*V3UtilsUnpausedIterator, error) {

	logs, sub, err := _V3Utils.contract.FilterLogs(opts, "Unpaused")
	if err != nil {
		return nil, err
	}
	return &V3UtilsUnpausedIterator{contract: _V3Utils.contract, event: "Unpaused", logs: logs, sub: sub}, nil
}

// WatchUnpaused is a free log subscription operation binding the contract event 0x5db9ee0a495bf2e6ff9c91a7834c1ba4fdd244a5e8aa4e537bd38aeae4b073aa.
//
// Solidity: event Unpaused(address account)
func (_V3Utils *V3UtilsFilterer) WatchUnpaused(opts *bind.WatchOpts, sink chan<- *V3UtilsUnpaused) (event.Subscription, error) {

	logs, sub, err := _V3Utils.contract.WatchLogs(opts, "Unpaused")
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(V3UtilsUnpaused)
				if err := _V3Utils.contract.UnpackLog(event, "Unpaused", log); err != nil {
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseUnpaused is a log parse operation binding the contract event 0x5db9ee0a495bf2e6ff9c91a7834c1ba4fdd244a5e8aa4e537bd38aeae4b073aa.
//
// Solidity: event Unpaused(address account)
func (_V3Utils *V3UtilsFilterer) ParseUnpaused(log types.Log) (*V3UtilsUnpaused, error) {
	event := new(V3UtilsUnpaused)
	if err := _V3Utils.contract.UnpackLog(event, "Unpaused", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// V3UtilsWithdrawAndCollectAndSwapIterator is returned from FilterWithdrawAndCollectAndSwap and is used to iterate over the raw logs and unpacked data for WithdrawAndCollectAndSwap events raised by the V3Utils contract.
type V3UtilsWithdrawAndCollectAndSwapIterator struct {
	Event *V3UtilsWithdrawAndCollectAndSwap // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *V3UtilsWithdrawAndCollectAndSwapIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(V3UtilsWithdrawAndCollectAndSwap)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(V3UtilsWithdrawAndCollectAndSwap)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *V3UtilsWithdrawAndCollectAndSwapIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *V3UtilsWithdrawAndCollectAndSwapIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// V3UtilsWithdrawAndCollectAndSwap represents a WithdrawAndCollectAndSwap event raised by the V3Utils contract.
type V3UtilsWithdrawAndCollectAndSwap struct {
	Nfpm    common.Address
	TokenId *big.Int
	Token   common.Address
	Amount  *big.Int
	Raw     types.Log // Blockchain specific contextual infos
}

// FilterWithdrawAndCollectAndSwap is a free log retrieval operation binding the contract event 0xc082f11600156d64071ed597a7b831f56741ad4e14954598e674e1ec2b61da0c.
//
// Solidity: event WithdrawAndCollectAndSwap(address indexed nfpm, uint256 indexed tokenId, address token, uint256 amount)
func (_V3Utils *V3UtilsFilterer) FilterWithdrawAndCollectAndSwap(opts *bind.FilterOpts, nfpm []common.Address, tokenId []*big.Int) (*V3UtilsWithdrawAndCollectAndSwapIterator, error) {

	var nfpmRule []interface{}
	for _, nfpmItem := range nfpm {
		nfpmRule = append(nfpmRule, nfpmItem)
	}
	var tokenIdRule []interface{}
	for _, tokenIdItem := range tokenId {
		tokenIdRule = append(tokenIdRule, tokenIdItem)
	}

	logs, sub, err := _V3Utils.contract.FilterLogs(opts, "WithdrawAndCollectAndSwap", nfpmRule, tokenIdRule)
	if err != nil {
		return nil, err
	}
	return &V3UtilsWithdrawAndCollectAndSwapIterator{contract: _V3Utils.contract, event: "WithdrawAndCollectAndSwap", logs: logs, sub: sub}, nil
}

// WatchWithdrawAndCollectAndSwap is a free log subscription operation binding the contract event 0xc082f11600156d64071ed597a7b831f56741ad4e14954598e674e1ec2b61da0c.
//
// Solidity: event WithdrawAndCollectAndSwap(address indexed nfpm, uint256 indexed tokenId, address token, uint256 amount)
func (_V3Utils *V3UtilsFilterer) WatchWithdrawAndCollectAndSwap(opts *bind.WatchOpts, sink chan<- *V3UtilsWithdrawAndCollectAndSwap, nfpm []common.Address, tokenId []*big.Int) (event.Subscription, error) {

	var nfpmRule []interface{}
	for _, nfpmItem := range nfpm {
		nfpmRule = append(nfpmRule, nfpmItem)
	}
	var tokenIdRule []interface{}
	for _, tokenIdItem := range tokenId {
		tokenIdRule = append(tokenIdRule, tokenIdItem)
	}

	logs, sub, err := _V3Utils.contract.WatchLogs(opts, "WithdrawAndCollectAndSwap", nfpmRule, tokenIdRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(V3UtilsWithdrawAndCollectAndSwap)
				if err := _V3Utils.contract.UnpackLog(event, "WithdrawAndCollectAndSwap", log); err != nil {
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseWithdrawAndCollectAndSwap is a log parse operation binding the contract event 0xc082f11600156d64071ed597a7b831f56741ad4e14954598e674e1ec2b61da0c.
//
// Solidity: event WithdrawAndCollectAndSwap(address indexed nfpm, uint256 indexed tokenId, address token, uint256 amount)
func (_V3Utils *V3UtilsFilterer) ParseWithdrawAndCollectAndSwap(log types.Log) (*V3UtilsWithdrawAndCollectAndSwap, error) {
	event := new(V3UtilsWithdrawAndCollectAndSwap)
	if err := _V3Utils.contract.UnpackLog(event, "WithdrawAndCollectAndSwap", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}
