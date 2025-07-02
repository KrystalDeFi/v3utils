const Order = {
    RebalanceAutoCompound: [
    	{name: "action", type: "RebalanceAutoCompoundAction"},
    ],
    
    RebalanceAutoCompoundAction: [
    	{name: "maxGasProportionX64", type: "int256"},
    	{name: "feeToPrincipalRatioThresholdX64", type: "int256"},
    ],
    
    TickOffsetCondition: [
    	{name: "gteTickOffset", type: "uint32"},
    	{name: "lteTickOffset", type: "uint32"},
    ],
    
    PriceOffsetCondition: [
    	{name: "baseToken", type: "uint32"},
    	{name: "gteOffsetSqrtPriceX96", type: "uint256"},
    	{name: "lteOffsetSqrtPriceX96", type: "uint256"},
    ],
    
    TokenRatioCondition: [
    	{name: "lteToken0RatioX64", type: "int256"},
    	{name: "gteToken0RatioX64", type: "int256"},
    ],
    
    Condition: [
    	{name: "type", type: "string"},
    	{name: "sqrtPriceX96", type: "int160"},
    	{name: "timeBuffer", type: "int64"},
    	{name: "tickOffsetCondition", type: "TickOffsetCondition"},
    	{name: "priceOffsetCondition", type: "PriceOffsetCondition"},
    	{name: "tokenRatioCondition", type: "TokenRatioCondition"},
    ],
    
    TickOffsetAction: [
    	{name: "tickLowerOffset", type: "uint32"},
    	{name: "tickUpperOffset", type: "uint32"},
    ],
    
    PriceOffsetAction: [
    	{name: "baseToken", type: "uint32"},
    	{name: "lowerOffsetSqrtPriceX96", type: "int160"},
    	{name: "upperOffsetSqrtPriceX96", type: "int160"},
    ],
    
    TokenRatioAction: [
    	{name: "tickWidth", type: "uint32"},
    	{name: "token0RatioX64", type: "int256"},
    ],
    
    RebalanceAction: [
    	{name: "maxGasProportionX64", type: "int256"},
    	{name: "swapSlippageX64", type: "int256"},
    	{name: "liquiditySlippageX64", type: "int256"},
    	{name: "type", type: "string"},
    	{name: "tickOffsetAction", type: "TickOffsetAction"},
    	{name: "priceOffsetAction", type: "PriceOffsetAction"},
    	{name: "tokenRatioAction", type: "TokenRatioAction"},
    ],
    
    RebalanceConfig: [
    	{name: "rebalanceCondition", type: "Condition"},
    	{name: "rebalanceAction", type: "RebalanceAction"},
    	{name: "autoCompound", type: "RebalanceAutoCompound"},
    	{name: "recurring", type: "bool"},
    ],
    
    RangeOrderCondition: [
    	{name: "zeroToOne", type: "bool"},
    	{name: "gteTickAbsolute", type: "int32"},
    	{name: "lteTickAbsolute", type: "int32"},
    ],
    
    RangeOrderAction: [
    	{name: "maxGasProportionX64", type: "int256"},
    	{name: "swapSlippageX64", type: "int256"},
    	{name: "withdrawSlippageX64", type: "int256"},
    ],
    
    RangeOrderConfig: [
    	{name: "condition", type: "RangeOrderCondition"},
    	{name: "action", type: "RangeOrderAction"},
    ],
    
    FeeBasedCondition: [
    	{name: "minFeeEarnedUsdX64", type: "int256"},
    ],
    
    TimeBasedCondition: [
    	{name: "intervalInSecond", type: "int256"},
    ],
    
    AutoCompoundCondition: [
    	{name: "type", type: "string"},
    	{name: "feeBasedCondition", type: "FeeBasedCondition"},
    	{name: "timeBasedCondition", type: "TimeBasedCondition"},
    ],
    
    AutoCompoundAction: [
    	{name: "maxGasProportionX64", type: "int256"},
    	{name: "poolSlippageX64", type: "int256"},
    	{name: "swapSlippageX64", type: "int256"},
    ],
    
    AutoCompoundConfig: [
    	{name: "condition", type: "AutoCompoundCondition"},
    	{name: "action", type: "AutoCompoundAction"},
    ],
    
    AutoExitConfig: [
    	{name: "condition", type: "Condition"},
    	{name: "action", type: "AutoExitAction"},
    ],
    
    AutoExitAction: [
    	{name: "maxGasProportionX64", type: "int256"},
    	{name: "swapSlippageX64", type: "int256"},
    	{name: "liquiditySlippageX64", type: "int256"},
    	{name: "tokenOutAddress", type: "address"},
    ],
    
    OrderConfig: [
    	{name: "rebalanceConfig", type: "RebalanceConfig"},
    	{name: "rangeOrderConfig", type: "RangeOrderConfig"},
    	{name: "autoCompoundConfig", type: "AutoCompoundConfig"},
    	{name: "autoExitConfig", type: "AutoExitConfig"},
    ],
    
    Order: [
    	{name: "chainId", type: "int64"},
    	{name: "nfpmAddress", type: "address"},
    	{name: "tokenId", type: "uint256"},
    	{name: "orderType", type: "string"},
    	{name: "config", type: "OrderConfig"},
    	{name: "signatureTime", type: "int64"},
    ],
}

module.exports = Order;
