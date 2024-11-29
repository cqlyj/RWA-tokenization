// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract dTSLA is ConfirmedOwner, FunctionsClient, ERC20 {
    using FunctionsRequest for FunctionsRequest.Request;
    using OracleLib for AggregatorV3Interface;
    using Strings for uint256;

    error dTSLA__InsufficientTSLABalance();
    error dTSLA__LessThanMinimalWithdrawalAmount();
    error dTSLA__TransferFailed();

    enum MintOrRedeem {
        MINT,
        REDEEM
    }

    struct dTslaRequest {
        uint256 amountOfToken;
        address requester;
        MintOrRedeem mintOrRedeem;
    }

    address constant AMOY_ROUTER = 0xC22a79eBA640940ABB6dF0f7982cc119578E11De;
    bytes32 constant AMOY_DON_ID =
        0x66756e2d706f6c79676f6e2d616d6f792d310000000000000000000000000000;
    address constant AMOY_TSLA_PRICE_FEED =
        0xc2e2848e28B9fE430Ab44F55a8437a33802a219C;
    address constant AMOY_USDC_PRICE_FEED =
        0x1b8739bB4CdF0089d07097A9Ae5Bd274b29C6F16;
    address constant AMOY_USDC_ADDRESS =
        0x6EEBe75caf9c579B3FBA9030760B84050283b50a;
    string private s_mintSourceCode;
    string private s_redeemSourceCode;
    uint64 private immutable i_subId;
    uint32 constant GAS_LIMIT = 300000;
    uint256 private s_portfolioBalance;
    uint256 constant MINIMAL_WITHDRAWAL_AMOUNT = 100e18;
    uint256 constant PRECISION = 10e18;
    uint256 constant ADDTIONAL_PRECISION = 10e10;
    // 200% collateral ratio
    // if there are $200 worth of TSLA in the brokerage, we can mint $100 worth of dTSLA
    uint256 constant COLLATERAL_RATIO = 200;
    uint256 constant COLLATERAL_PRECISION = 100;

    mapping(bytes32 requestId => dTslaRequest request)
        private s_requestIdToRequest;
    mapping(address user => uint256 pendingWithdrawalAmount)
        private s_userToWithdrawalAmount;
    uint8 donHostedSecretsSlotID = 0;
    uint64 donHostedSecretsVersion = 1732872201;

    constructor(
        uint64 subId,
        string memory mintSourceCode,
        string memory redeemSourceCode
    )
        ConfirmedOwner(msg.sender)
        FunctionsClient(AMOY_ROUTER)
        ERC20("Backed TSLA", "bTSLA")
    {
        s_mintSourceCode = mintSourceCode;
        s_redeemSourceCode = redeemSourceCode;
        i_subId = subId;
    }

    // Send an HTTP request to:
    // 1. see how much TSLA is bought
    // 2. if enough TSLA is bought, mint dTSLA
    // This is a 2 transaction function
    function sendMintRequest(
        uint256 amount
    ) external onlyOwner returns (bytes32) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_mintSourceCode);

        req.addDONHostedSecrets(
            donHostedSecretsSlotID,
            donHostedSecretsVersion
        );

        bytes32 requestId = _sendRequest(
            req.encodeCBOR(),
            i_subId,
            GAS_LIMIT,
            AMOY_DON_ID
        );

        s_requestIdToRequest[requestId] = dTslaRequest(
            amount,
            msg.sender,
            MintOrRedeem.MINT
        );

        return requestId;
    }

    // return the amount of TSLA value in USD is stored in brokerage
    // if we have enough TSLA value in USD, mint dTSLA
    function _mintFulfillRequest(
        bytes32 requestId,
        bytes memory response
    ) internal {
        uint256 amountOfTokensToMint = s_requestIdToRequest[requestId]
            .amountOfToken;

        s_portfolioBalance = uint256(bytes32(response));

        // if s_portfolioBalance >= amountOfTokensToMint => mint dTSLA
        // How much TSLA in dollars do we have in the brokerage?
        // How much TSLA in dollars do we need to mint dTSLA?
        if (_getTslaBalance(amountOfTokensToMint) > s_portfolioBalance) {
            revert dTSLA__InsufficientTSLABalance();
        }

        if (amountOfTokensToMint != 0) {
            _mint(
                s_requestIdToRequest[requestId].requester,
                amountOfTokensToMint
            );
        }
    }

    function _getTslaBalance(
        uint256 amountOfTokensToMint
    ) internal view returns (uint256) {
        uint256 calculatedNewTotalValue = getCalculatedNewTotalValue(
            amountOfTokensToMint
        );
        return
            (calculatedNewTotalValue * COLLATERAL_RATIO) / COLLATERAL_PRECISION;
    }

    function getCalculatedNewTotalValue(
        uint256 amountOfTokensToMint
    ) internal view returns (uint256) {
        return
            ((totalSupply() + amountOfTokensToMint) * getTslaPrice()) /
            PRECISION;
    }

    function getTslaPrice() public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            AMOY_TSLA_PRICE_FEED
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return uint256(price) * ADDTIONAL_PRECISION;
    }

    // user sends a request to sell TSLA for USDC(redemptionToken)
    // This will have the chainlink function call alpaca(bank) and do the following:
    // 1. Sell TSLA on the brokerage
    // 2. Buy USDC on the brokerage
    // 3. Send USDC to the contract for user to withdraw
    function sendRedeemRequest(uint256 amountdTsla) external {
        uint256 amountdTslaInUSD = getUsdcValueOfUsd(
            getUsdValueOfTsla(amountdTsla)
        );
        if (amountdTslaInUSD < MINIMAL_WITHDRAWAL_AMOUNT) {
            revert dTSLA__LessThanMinimalWithdrawalAmount();
        }

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_redeemSourceCode);

        string[] memory args = new string[](2);
        args[0] = amountdTsla.toString();
        args[1] = amountdTslaInUSD.toString();
        req.setArgs(args);

        bytes32 requestId = _sendRequest(
            req.encodeCBOR(),
            i_subId,
            GAS_LIMIT,
            AMOY_DON_ID
        );

        s_requestIdToRequest[requestId] = dTslaRequest(
            amountdTsla,
            msg.sender,
            MintOrRedeem.REDEEM
        );

        _burn(msg.sender, amountdTsla);
    }

    function getUsdcValueOfUsd(
        uint256 amountUsd
    ) public view returns (uint256) {
        return (amountUsd * getUsdcPrice()) / PRECISION;
    }

    function getUsdValueOfTsla(
        uint256 amountdTsla
    ) public view returns (uint256) {
        return (amountdTsla * getTslaPrice()) / PRECISION;
    }

    function getUsdcPrice() public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            AMOY_USDC_PRICE_FEED
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return uint256(price) * ADDTIONAL_PRECISION;
    }

    function _redeemFulfillRequest(
        bytes32 requestId,
        bytes memory response
    ) internal {
        uint256 usdcAmount = uint256(bytes32(response));
        if (usdcAmount == 0) {
            uint256 amountOfdTslaBurned = s_requestIdToRequest[requestId]
                .amountOfToken;
            _mint(
                s_requestIdToRequest[requestId].requester,
                amountOfdTslaBurned
            );

            return;
        }

        s_userToWithdrawalAmount[
            s_requestIdToRequest[requestId].requester
        ] += usdcAmount;
    }

    function withdraw() external {
        uint256 amount = s_userToWithdrawalAmount[msg.sender];
        s_userToWithdrawalAmount[msg.sender] = 0;
        bool success = ERC20(AMOY_USDC_ADDRESS).transfer(msg.sender, amount);
        if (!success) {
            revert dTSLA__TransferFailed();
        }
    }

    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory /*err*/
    ) internal override {
        if (s_requestIdToRequest[requestId].mintOrRedeem == MintOrRedeem.MINT) {
            _mintFulfillRequest(requestId, response);
        } else {
            _redeemFulfillRequest(requestId, response);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function getPortfolioBalance() external view returns (uint256) {
        return s_portfolioBalance;
    }

    function getPendingWithdrawalAmount() external view returns (uint256) {
        return s_userToWithdrawalAmount[msg.sender];
    }

    function getMintSourceCode() external view returns (string memory) {
        return s_mintSourceCode;
    }

    function getRedeemSourceCode() external view returns (string memory) {
        return s_redeemSourceCode;
    }

    function getSubId() external view returns (uint64) {
        return i_subId;
    }

    function getGasLimit() external pure returns (uint32) {
        return GAS_LIMIT;
    }

    function getRequestIdToRequest(
        bytes32 requestId
    ) external view returns (dTslaRequest memory) {
        return s_requestIdToRequest[requestId];
    }
}
