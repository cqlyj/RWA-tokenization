-include .env

install:
	@forge install smartcontractkit/chainlink-brownie-contracts --no-commit && forge install openzeppelin/openzeppelin-contracts --no-commit

deploy :; forge script script/DeployDTsla.s.sol --sender 0xFB6a372F2F51a002b390D18693075157A459641F --account burner --rpc-url ${AMOY_RPC_URL} --broadcast

send-request:
	@cast send 0xDe782B1E6c4025D729e052065f810b2Bad7a537F "sendMintRequest(uint256)" 1000000000000000000 --rpc-url $(AMOY_RPC_URL) --private-key $(PRIVATE_KEY)

getBalance:
	@cast call 0xDe782B1E6c4025D729e052065f810b2Bad7a537F "getPortfolioBalance()" --rpc-url $(AMOY_RPC_URL)

checkToken:
	@cast call 0xDe782B1E6c4025D729e052065f810b2Bad7a537F "balanceOf(address)" 0xFB6a372F2F51a002b390D18693075157A459641F --rpc-url $(AMOY_RPC_URL)