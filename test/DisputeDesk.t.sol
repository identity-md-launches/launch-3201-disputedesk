// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DisputeDesk, IERC20, IIntake, OracleAttestation} from "src/DisputeDesk.sol";

// The repository deliberately has no external test dependencies. These are only
// the Foundry cheatcodes this suite uses; everything ships in this one file.
interface DeskVm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }
    function chainId(uint256) external;
    function warp(uint256) external;
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function etch(address, bytes calldata) external;
    function addr(uint256) external pure returns (address);
    function sign(uint256, bytes32) external pure returns (uint8, bytes32, bytes32);
    function expectRevert(bytes4) external;
    function expectRevert() external;
    function expectEmit(bool, bool, bool, bool, address) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
    function parseJsonString(string calldata, string calldata) external pure returns (string memory);
    function parseJsonUint(string calldata, string calldata) external pure returns (uint256);
    function parseJsonKeys(string calldata, string calldata) external pure returns (string[] memory);
    function toString(bytes32) external pure returns (string memory);
    function toString(address) external pure returns (string memory);
}

abstract contract DeskAssertions {
    DeskVm internal constant vm = DeskVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertEq(uint256 a, uint256 b, string memory why) internal pure {
        require(a == b, why);
    }

    function assertEq(address a, address b, string memory why) internal pure {
        require(a == b, why);
    }

    function assertEq(bytes32 a, bytes32 b, string memory why) internal pure {
        require(a == b, why);
    }

    function assertEq(bytes memory a, bytes memory b, string memory why) internal pure {
        require(keccak256(a) == keccak256(b), why);
    }

    function assertEq(string memory a, string memory b, string memory why) internal pure {
        require(keccak256(bytes(a)) == keccak256(bytes(b)), why);
    }

    function assertTrue(bool condition, string memory why) internal pure {
        require(condition, why);
    }

    function bounded(uint256 n, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + n % (hi - lo + 1);
    }

    function lowercase(string memory value) internal pure returns (string memory) {
        bytes memory b = bytes(value);
        for (uint256 i; i < b.length; ++i) {
            if (b[i] >= 0x41 && b[i] <= 0x5a) b[i] = bytes1(uint8(b[i]) + 32);
        }
        return string(b);
    }
}

/// @dev Configurable ERC-20 with realistic balances/allowances, optional-return
/// variants, and hooks for observing and attacking external-call boundaries.
contract DeskToken is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    // 0=true, 1=false, 2=no data, 3=short data, 4=noncanonical true, 5=revert.
    uint8 public transferMode;
    uint8 public transferFromMode;
    uint8 public approveMode;
    bool public requireZeroApproval;
    uint256 public incomingBurn;
    address public hookTarget;
    bytes public hookData;
    uint8 public hookOn; // 1=transfer, 2=transferFrom, 3=approve
    bool public hookSucceeded;
    bytes public hookResult;
    uint256 public hookCalls;
    DisputeDesk public observedDesk;
    bytes32 public observedRequest;
    bool public sawSettlementEffects;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function configure(uint8 t, uint8 f, uint8 a, uint256 burn) external {
        transferMode = t;
        transferFromMode = f;
        approveMode = a;
        incomingBurn = burn;
    }

    function setRequireZeroApproval(bool value) external {
        requireZeroApproval = value;
    }

    function seedAllowance(address holder, address spender, uint256 amount) external {
        allowance[holder][spender] = amount;
    }

    function setHook(uint8 on, address target, bytes calldata data) external {
        hookOn = on;
        hookTarget = target;
        hookData = data;
        hookCalls = 0;
        hookSucceeded = false;
        delete hookResult;
    }

    function observeSettlement(DisputeDesk desk, bytes32 id) external {
        observedDesk = desk;
        observedRequest = id;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (address(observedDesk) != address(0)) {
            DisputeDesk.Challenge memory c = observedDesk.challenges(observedRequest);
            sawSettlementEffects = c.status != DisputeDesk.Status.Open
                && observedDesk.activeChallenge(c.claimHash) == bytes32(0)
                && observedDesk.openChallenges(c.challenger) == 0 && observedDesk.escrowedBonds() == 0
                && observedDesk.reservedBounties() == 0;
        }
        _hook(1);
        _move(msg.sender, to, amount, 0);
        return _respond(transferMode);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "token allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _hook(2);
        _move(from, to, amount, incomingBurn);
        return _respond(transferFromMode);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (requireZeroApproval && amount != 0 && allowance[msg.sender][spender] != 0) return false;
        _hook(3);
        allowance[msg.sender][spender] = amount;
        return _respond(approveMode);
    }

    function _move(address from, address to, uint256 amount, uint256 burn) private {
        require(balanceOf[from] >= amount && burn <= amount, "token balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount - burn;
        totalSupply -= burn;
    }

    function _hook(uint8 on) private {
        if (hookOn != on || hookTarget == address(0)) return;
        ++hookCalls;
        (hookSucceeded, hookResult) = hookTarget.call(hookData);
    }

    function _respond(uint8 mode) private pure returns (bool) {
        if (mode == 1) return false;
        if (mode == 2) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (mode == 3) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (mode == 4) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        require(mode != 5, "token reverted");
        return true;
    }
}

/// @dev Records the exact wire request and delivers using the recorded selectors.
/// Delivery bubbles the consumer's revert and deliberately permits replay attempts.
contract MockIntake is IIntake {
    struct Request {
        bytes32 action;
        bytes body;
        address target;
        bytes4 selector;
        bytes4 onFailure;
        address asset;
        uint256 amount;
    }
    mapping(bytes32 => Request) private requests;
    uint256 public nonce;
    bytes32 public lastId;
    bool public forceId;
    bytes32 public forcedId;
    bool public rejectRequest;
    uint256 public feeDiscount;
    address public hookTarget;
    bytes public hookData;
    bool public hookSucceeded;
    bytes public hookResult;

    function nextId() public view returns (bytes32) {
        return forceId ? forcedId : keccak256(abi.encode(address(this), nonce + 1));
    }

    function request(bytes32 id) external view returns (Request memory) {
        return requests[id];
    }

    function setForcedId(bool enabled, bytes32 id) external {
        forceId = enabled;
        forcedId = id;
    }

    function setReject(bool value) external {
        rejectRequest = value;
    }

    function setFeeDiscount(uint256 value) external {
        feeDiscount = value;
    }

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external returns (bytes32 id) {
        require(!rejectRequest, "intake refused request");
        id = nextId();
        ++nonce;
        requests[id] = Request(action, body, callback.target, callback.selector, onFailure, asset, amount);
        lastId = id;
        (bool ok, bytes memory ret) =
            asset.call(abi.encodeCall(IERC20.transferFrom, (msg.sender, address(this), amount - feeDiscount)));
        require(ok && (ret.length == 0 || (ret.length == 32 && abi.decode(ret, (bool)))), "fee pull failed");
        if (hookTarget != address(0)) (hookSucceeded, hookResult) = hookTarget.call(hookData);
    }

    function deliver(bytes32 id, OracleAttestation.Attestation calldata a, bytes calldata signature) external {
        Request storage r = requests[id];
        _call(r.target, abi.encodeWithSelector(r.selector, id, a, signature), 200_000);
    }

    function fail(bytes32 id, uint8 status) external {
        Request storage r = requests[id];
        _call(
            r.target,
            abi.encodeWithSelector(r.onFailure, id, status, bytes32("body_refused"), uint16(0), uint16(0), bytes("")),
            200_000
        );
    }

    function rawCallback(address target, bytes calldata data) external {
        _call(target, data, 200_000);
    }

    function _call(address target, bytes memory data, uint256 gasLimit) private {
        require(target.code.length != 0, "callback target missing");
        (bool ok, bytes memory ret) = target.call{gas: gasLimit}(data);
        if (!ok) {
            assembly ("memory-safe") { revert(add(ret, 32), mload(ret)) }
        }
    }
}

/// @dev The production signer is fixed. Unit tests install an ERC-1271 verifier at
/// that address, verifying real ECDSA signatures from the published protocol test
/// key. It does NOT accept arbitrary signatures. A separate vector pins the real
/// protocol digest; dedicated EOA tests remove this mock and substitute only the
/// runtime signer constant to exercise production ECDSA acceptance.
contract DeskTestSigner {
    address private immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        if (signature.length != 65) return 0xffffffff;
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        return ecrecover(digest, v, r, s) == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

abstract contract DeskFixture is DeskAssertions {
    uint256 internal constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    address internal constant NEWSROOM = 0xBE80e5979313cF8AFF2b8E54e615FE3ECd8358f5;
    bytes32 internal constant RUBRIC = 0x494c69552db9fd948e2f4bce26da4d0b3e08d2e5b1cdfbade546af42e677b0b9;
    string internal constant RUBRIC_URI = "https://openinterest-ai.github.io/paper/rubric.txt";
    string internal constant RECORD_URI = "https://openinterest-ai.github.io/paper/";
    string internal constant EVIDENCE_URI = "https://evidence.example/arithmetic.txt";
    uint256 internal constant INITIAL_POOL = 45e17;
    uint256 internal constant INITIAL_USER = 100e18;
    DeskToken internal token;
    MockIntake internal intake;
    DisputeDesk internal desk;
    address internal alice;
    address internal bob;
    bytes32 internal edition;
    bytes32 internal claim;
    bytes32 internal evidence;

    event PoolFunded(address indexed funder, uint256 amount);
    event ChallengeFiled(
        bytes32 indexed requestId,
        address indexed challenger,
        bytes32 indexed claimHash,
        bytes32 editionHash,
        string evidenceURI,
        bytes32 evidenceHash
    );
    event ChallengeSettled(
        bytes32 indexed requestId, DisputeDesk.Status status, address indexed recipient, uint256 amount
    );
    event Correction(bytes32 indexed editionHash, bytes32 indexed claimHash, bytes32 indexed requestId);
    event OracleFailure(bytes32 indexed requestId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered);
    event BondSet(uint256 bond);
    event BountyMultiplierSet(uint256 bountyMultiplier);
    event OracleFeeSet(uint256 oracleFee);
    event RubricSet(bytes32 indexed rubricHash, string rubricURI);
    event RecordURISet(string recordURI);
    event IntakeSet(address indexed intake);
    event PausedSet(bool paused);

    function setUp() public virtual {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        alice = address(uint160(uint256(keccak256("DisputeDesk challenger Alice"))));
        bob = address(uint160(uint256(keccak256("DisputeDesk challenger Bob"))));
        edition = sha256("Open Interest test edition: 2 + 2 = 5.");
        claim = sha256("2 + 2 = 5.");
        evidence = sha256("2 + 2 = 4.");
        token = new DeskToken();
        intake = new MockIntake();
        desk = new DisputeDesk(address(token), address(intake), NEWSROOM, 1e18, 1, 5e17, RUBRIC);
        _installSigner();
        vm.startPrank(NEWSROOM);
        desk.setRubric(RUBRIC, RUBRIC_URI);
        desk.setRecordURI(RECORD_URI);
        vm.stopPrank();
        token.mint(address(this), INITIAL_POOL);
        token.approve(address(desk), type(uint256).max);
        desk.fundPool(INITIAL_POOL);
        token.mint(alice, INITIAL_USER);
        token.mint(bob, INITIAL_USER);
        vm.prank(alice);
        token.approve(address(desk), type(uint256).max);
        vm.prank(bob);
        token.approve(address(desk), type(uint256).max);
        vm.prank(NEWSROOM);
        desk.setPaused(false);
    }

    function _installSigner() internal {
        DeskTestSigner signer = new DeskTestSigner(vm.addr(SIGNER_KEY));
        vm.etch(desk.oracleSigner(), address(signer).code);
    }

    function _file(address who, bytes32 which) internal returns (bytes32 id) {
        vm.prank(who);
        return desk.challenge(edition, which, EVIDENCE_URI, evidence);
    }

    function _attestation(bytes32 id, bool yes) internal view returns (OracleAttestation.Attestation memory a) {
        a.requestId = keccak256(abi.encode("oracle UUID distinct from intake ID", id));
        a.chainId = 1;
        a.questionHash = keccak256(abi.encode("resolved relative-window question", id));
        a.answer = abi.encode(yes);
        a.fromBlock = 100;
        a.toBlock = 200;
        a.blockHash = keccak256("closing block");
        a.panelJobId = keccak256(abi.encode("panel", id));
        a.panelSize = 5;
        a.quorum = 3;
        a.agreed = 3;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 604800);
    }

    function _signature(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, desk.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _verdict(bytes32 id, bool yes) internal {
        OracleAttestation.Attestation memory a = _attestation(id, yes);
        MockIntake(desk.challenges(id).intake).deliver(id, a, _signature(a));
    }

    function _outcome(bytes32 id, uint256 outcome) internal {
        if (outcome < 2) _verdict(id, outcome == 0);
        else MockIntake(desk.challenges(id).intake).fail(id, 1);
    }

    function _accounting(uint256 pool, uint256 reserved, uint256 escrow) internal view {
        assertEq(desk.poolBalance(), pool, "pool accounting");
        assertEq(desk.reservedBounties(), reserved, "reservation accounting");
        assertEq(desk.escrowedBonds(), escrow, "escrow accounting");
        assertEq(token.balanceOf(address(desk)), pool + escrow, "physical balance = pool + escrow");
        assertTrue(reserved <= pool, "reservations exceed pool");
    }

    function _closed(bytes32 id, DisputeDesk.Status status) internal view {
        DisputeDesk.Challenge memory c = desk.challenges(id);
        assertEq(uint256(c.status), uint256(status), "terminal status");
        assertEq(desk.activeChallenge(c.claimHash), bytes32(0), "claim remains active");
        assertEq(desk.openChallenges(c.challenger), 0, "open count remains");
    }

    function _assertPristineFiling() internal view {
        _accounting(INITIAL_POOL, 0, 0);
        assertEq(token.balanceOf(alice), INITIAL_USER, "failed filing took bond");
        assertEq(token.balanceOf(address(intake)), 0, "failed filing paid oracle");
        assertEq(desk.openChallenges(alice), 0, "failed filing incremented count");
        assertEq(desk.activeChallenge(claim), bytes32(0), "failed filing locked claim");
        assertEq(intake.nonce(), 0, "failed filing persisted request");
        assertEq(token.allowance(address(desk), address(intake)), 0, "residual intake approval");
    }
}

contract DisputeDeskLifecycleTest is DeskFixture {
    function test_exactMainnetConstructorNeedsNoDependencyCode() public {
        address mainnetToken = address(bytes20(hex"d34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7"));
        address mainnetIntake = address(bytes20(hex"a43e6f75ee006411f79ac1c84120606c2330de82"));
        assertEq(mainnetToken.code.length, 0, "test must not depend on live token");
        assertEq(mainnetIntake.code.length, 0, "test must not depend on live intake");
        DisputeDesk deployed = new DisputeDesk(mainnetToken, mainnetIntake, NEWSROOM, 1e18, 1, 5e17, RUBRIC);
        assertEq(deployed.imdToken(), mainnetToken, "deployment token");
        assertEq(deployed.intake(), mainnetIntake, "deployment intake");
        assertEq(deployed.owner(), NEWSROOM, "owner must be explicit newsroom, not deployer");
        assertEq(deployed.bond(), 1e18, "initial bond");
        assertEq(deployed.bountyMultiplier(), 1, "initial multiplier");
        assertEq(deployed.oracleFee(), 5e17, "initial fee");
        assertEq(deployed.rubricHash(), RUBRIC, "initial rubric hash");
        assertTrue(deployed.paused(), "deployment must be paused");
        assertEq(deployed.rubricURI(), "", "rubric URI must start empty");
        assertEq(deployed.recordURI(), "", "record URI must start empty");
        assertEq(deployed.poolBalance(), 0, "initial pool");
        assertEq(deployed.reservedBounties(), 0, "initial reservations");
        assertEq(deployed.escrowedBonds(), 0, "initial escrow");
        assertEq(deployed.COOLDOWN_SECONDS(), 604800, "cooldown constant");
        assertEq(deployed.PANEL_SIZE(), 5, "panel constant");
        assertEq(deployed.QUORUM(), 3, "quorum constant");
        assertEq(deployed.metadata(), "DisputeDesk v1: trial period - verdicts bind from day one", "trial metadata");
    }

    function test_unpauseRequiresBothURIs() public {
        DisputeDesk fresh = new DisputeDesk(address(token), address(intake), NEWSROOM, 1e18, 1, 5e17, RUBRIC);
        vm.startPrank(NEWSROOM);
        vm.expectRevert(DisputeDesk.NotConfigured.selector);
        fresh.setPaused(false);
        fresh.setRubric(RUBRIC, RUBRIC_URI);
        vm.expectRevert(DisputeDesk.NotConfigured.selector);
        fresh.setPaused(false);
        fresh.setRecordURI(RECORD_URI);
        fresh.setPaused(false);
        vm.stopPrank();
        assertTrue(!fresh.paused(), "configured newsroom can unpause");
    }

    function test_filingEscrowsBondAndRecordsExactRequest() public {
        bytes32 predicted = intake.nextId();
        vm.expectEmit(true, true, true, true, address(desk));
        emit ChallengeFiled(predicted, alice, claim, edition, EVIDENCE_URI, evidence);
        bytes32 id = _file(alice, claim);
        assertEq(id, predicted, "must use intake returned ID");
        _accounting(INITIAL_POOL, 15e17, 5e17);
        assertEq(token.balanceOf(alice), INITIAL_USER - 1e18, "bond pulled once");
        assertEq(token.balanceOf(address(intake)), 5e17, "fee paid immediately");
        assertEq(token.balanceOf(NEWSROOM), 0, "owner receives nothing at filing");
        assertEq(token.allowance(address(desk), address(intake)), 0, "approval cleared");
        assertEq(desk.activeChallenge(claim), id, "claim index");
        assertEq(desk.openChallenges(alice), 1, "open count");
        DisputeDesk.Challenge memory c = desk.challenges(id);
        assertEq(c.challenger, alice, "stored challenger");
        assertEq(c.bond, 1e18, "stored bond");
        assertEq(c.bounty, 1e18, "stored bounty");
        assertEq(c.bountyMultiplier, 1, "stored multiplier");
        assertEq(c.oracleFee, 5e17, "stored fee");
        assertEq(c.editionHash, edition, "stored edition");
        assertEq(c.claimHash, claim, "stored claim");
        assertEq(c.evidenceURI, EVIDENCE_URI, "stored evidence URI");
        assertEq(c.evidenceHash, evidence, "stored evidence pin");
        assertEq(c.rubricHash, RUBRIC, "stored rubric");
        assertEq(c.rubricURI, RUBRIC_URI, "stored rubric URI");
        assertEq(c.recordURI, RECORD_URI, "stored record URI");
        assertEq(c.intake, address(intake), "stored intake");
        assertEq(c.requestId, id, "stored request");
        assertEq(c.filedAt, block.timestamp, "stored filing time");
        assertEq(uint256(c.status), uint256(DisputeDesk.Status.Open), "initial status");
        MockIntake.Request memory r = intake.request(id);
        assertEq(r.action, bytes32("oracle.request@oracle-1"), "action must be padded text, not hash");
        assertEq(r.target, address(desk), "callback target");
        assertEq(bytes32(r.selector), bytes32(desk.settle.selector), "result selector");
        assertEq(bytes32(r.onFailure), bytes32(desk.failure.selector), "failure selector");
        assertEq(r.asset, address(token), "oracle payment asset");
        assertEq(r.amount, 5e17, "oracle payment amount");
    }

    function test_upheldPaysTwoIMDAndEmitsCorrection() public {
        bytes32 id = _file(alice, claim);
        vm.expectEmit(true, true, true, true, address(desk));
        emit Correction(edition, claim, id);
        vm.expectEmit(true, true, false, true, address(desk));
        emit ChallengeSettled(id, DisputeDesk.Status.Upheld, alice, 2e18);
        _verdict(id, true);
        _closed(id, DisputeDesk.Status.Upheld);
        _accounting(3e18, 0, 0);
        assertEq(token.balanceOf(alice), INITIAL_USER + 1e18, "upheld payout to wei");
        assertEq(token.balanceOf(NEWSROOM), 0, "owner cannot take upheld escrow");
        assertEq(token.balanceOf(address(intake)), 5e17, "fee stays spent");
        assertEq(desk.cooldownUntil(claim), 0, "upheld must not start cooldown");
        bytes32 next = _file(bob, claim);
        assertTrue(next != id, "upheld claim may be challenged again");
    }

    function test_rejectedPaysOnlyRemainderToOwnerAndCooldownStartsAtSettlement() public {
        bytes32 id = _file(alice, claim);
        vm.warp(block.timestamp + 9 days);
        uint256 settledAt = block.timestamp;
        vm.recordLogs();
        _verdict(id, false);
        _assertNoCorrection(vm.getRecordedLogs());
        _closed(id, DisputeDesk.Status.Rejected);
        _accounting(INITIAL_POOL, 0, 0);
        assertEq(token.balanceOf(alice), INITIAL_USER - 1e18, "rejected loses whole bond");
        assertEq(token.balanceOf(NEWSROOM), 5e17, "owner gets only escrow remainder");
        assertEq(token.balanceOf(address(intake)), 5e17, "fee stays spent on rejection");
        assertEq(desk.cooldownUntil(claim), settledAt + 604800, "cooldown must start at verdict");
        vm.expectRevert(DisputeDesk.ClaimInCooldown.selector);
        _file(bob, claim);
        vm.warp(settledAt + 604799);
        vm.expectRevert(DisputeDesk.ClaimInCooldown.selector);
        _file(alice, claim);
        vm.warp(settledAt + 604800);
        _file(bob, claim);
    }

    function testFuzz_failureBothStatusesRefundOnlyRemainder(uint8 statusSeed) public {
        uint8 status = uint8(bounded(statusSeed, 1, 2));
        bytes32 id = _file(alice, claim);
        vm.expectEmit(true, false, false, true, address(desk));
        emit OracleFailure(id, status, bytes32("body_refused"), 0, 0);
        vm.expectEmit(true, true, false, true, address(desk));
        emit ChallengeSettled(id, DisputeDesk.Status.Failed, alice, 5e17);
        vm.recordLogs();
        intake.fail(id, status);
        _assertNoCorrection(vm.getRecordedLogs());
        _closed(id, DisputeDesk.Status.Failed);
        _accounting(INITIAL_POOL, 0, 0);
        assertEq(token.balanceOf(alice), INITIAL_USER - 5e17, "failure refunds remainder only");
        assertEq(token.balanceOf(NEWSROOM), 0, "failure cannot pay owner");
        assertEq(token.balanceOf(address(intake)), 5e17, "failure does not refund oracle fee");
        assertEq(desk.cooldownUntil(claim), 0, "failure must not impose cooldown");
        _file(alice, claim);
    }

    function _assertNoCorrection(DeskVm.Log[] memory logs) private view {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(desk)) {
                assertTrue(
                    logs[i].topics[0] != keccak256("Correction(bytes32,bytes32,bytes32)"),
                    "non-upheld outcome emitted correction"
                );
            }
        }
    }

    function testFuzz_settlementIsExactlyOnceAcrossAllCallbackCombinations(uint8 terminalSeed) public {
        uint256 outcome = terminalSeed % 3;
        bytes32 id = _file(alice, claim);
        _outcome(id, outcome);
        uint256 balance = token.balanceOf(alice);
        uint256 ownerBalance = token.balanceOf(NEWSROOM);
        uint256 pool = desk.poolBalance();
        OracleAttestation.Attestation memory a = _attestation(id, true);
        bytes memory signature = _signature(a);
        vm.expectRevert(DisputeDesk.NotOpen.selector);
        intake.deliver(id, a, signature);
        a.answer = abi.encode(false);
        signature = _signature(a);
        vm.expectRevert(DisputeDesk.NotOpen.selector);
        intake.deliver(id, a, signature);
        vm.expectRevert(DisputeDesk.NotOpen.selector);
        intake.fail(id, 1);
        vm.expectRevert(DisputeDesk.NotOpen.selector);
        intake.fail(id, 2);
        assertEq(token.balanceOf(alice), balance, "replay changed challenger balance");
        assertEq(token.balanceOf(NEWSROOM), ownerBalance, "replay changed owner balance");
        _accounting(pool, 0, 0);
    }

    function test_pausedBlocksFilingButFundingAndEverySettlementStillWork() public {
        bytes32 yes = _file(alice, claim);
        bytes32 no = _file(alice, sha256("second claim"));
        bytes32 failed = _file(alice, sha256("third claim"));
        bytes32 fourthClaim = sha256("fourth claim");
        vm.prank(NEWSROOM);
        desk.setPaused(true);
        vm.expectRevert(DisputeDesk.Paused.selector);
        _file(bob, fourthClaim);
        vm.expectEmit(true, false, false, true, address(desk));
        emit PoolFunded(bob, 1e18);
        vm.prank(bob);
        desk.fundPool(1e18);
        _verdict(yes, true);
        _verdict(no, false);
        intake.fail(failed, 2);
        _accounting(4e18, 0, 0);
        assertEq(token.balanceOf(alice), INITIAL_USER - 5e17, "all three payouts while paused");
        assertEq(token.balanceOf(NEWSROOM), 5e17, "rejection while paused");
    }

    function test_poolMustCoverBountyAndFeeAndCannotCountEscrowOrDonations() public {
        // Leave exactly 1 wei less than the reservation free after two filings.
        bytes32 first = _file(alice, claim);
        _file(bob, sha256("other claim"));
        bytes32 insolvent = sha256("insolvent");
        vm.prank(NEWSROOM);
        desk.setOracleFee(5e17 + 1);
        vm.expectRevert(DisputeDesk.InsufficientPool.selector);
        _file(bob, insolvent);
        token.mint(address(desk), 10e18); // a donation is not fundPool
        vm.expectRevert(DisputeDesk.InsufficientPool.selector);
        _file(bob, insolvent);
        vm.prank(bob);
        desk.fundPool(1);
        _file(bob, sha256("exactly solvent"));
        assertEq(desk.poolBalance(), INITIAL_POOL + 1, "only fundPool credits pool");
        assertEq(desk.reservedBounties(), INITIAL_POOL + 1, "exact boundary accepted");
        assertEq(
            token.balanceOf(address(desk)),
            desk.poolBalance() + desk.escrowedBonds() + 10e18,
            "donation must stay separate from liabilities"
        );
        intake.fail(first, 1); // released reservations make space, not extra pool
        assertEq(desk.poolBalance(), INITIAL_POOL + 1, "failure cannot increase pool");
    }

    function test_duplicateClaimAcrossEditionsAndCallersIsBlocked() public {
        _file(alice, claim);
        bytes32 otherEdition = sha256("another edition");
        vm.expectRevert(DisputeDesk.ClaimAlreadyOpen.selector);
        vm.prank(bob);
        desk.challenge(otherEdition, claim, "https://different.example", bytes32(0));
        _accounting(INITIAL_POOL, 15e17, 5e17);
        assertEq(desk.openChallenges(bob), 0, "duplicate cannot consume a slot");
    }

    function test_threeOpenLimitIsPerChallengerAndEveryOutcomeReleasesOneSlot() public {
        token.mint(address(this), 10e18);
        desk.fundPool(10e18);
        bytes32[3] memory ids;
        for (uint256 i; i < 3; ++i) {
            ids[i] = _file(alice, bytes32(i + 1));
        }
        vm.expectRevert(DisputeDesk.TooManyOpenChallenges.selector);
        _file(alice, bytes32(uint256(4)));
        _file(bob, bytes32(uint256(5)));
        for (uint256 i; i < 3; ++i) {
            _outcome(ids[i], i);
            assertEq(desk.openChallenges(alice), 2, "settlement must release one slot");
            _file(alice, bytes32(i + 6));
            assertEq(desk.openChallenges(alice), 3, "released slot reusable");
        }
        assertEq(desk.openChallenges(bob), 1, "other challenger count isolated");
    }

    function test_allTermsAreLockedAndOriginalIntakeSettlesAfterMigration() public {
        bytes32 oldId = _file(alice, claim);
        bytes memory oldTerms = abi.encode(desk.challenges(oldId));
        bytes memory oldBody = intake.request(oldId).body;
        MockIntake replacement = new MockIntake();
        vm.startPrank(NEWSROOM);
        desk.setBond(2e18);
        desk.setBountyMultiplier(2);
        desk.setOracleFee(7e17);
        desk.setRubric(sha256("new rubric"), "https://paper.example/new-rubric");
        desk.setRecordURI("https://paper.example/new-record/");
        desk.setIntake(address(replacement));
        vm.stopPrank();
        assertEq(abi.encode(desk.challenges(oldId)), oldTerms, "a dial mutated an open challenge");
        assertEq(intake.request(oldId).body, oldBody, "filed request body changed");
        token.mint(address(this), 5e18);
        desk.fundPool(5e18);
        bytes32 newId = _file(bob, sha256("after migration"));
        DisputeDesk.Challenge memory c = desk.challenges(newId);
        assertEq(c.bond, 2e18, "new bond");
        assertEq(c.bounty, 4e18, "new bounty");
        assertEq(c.bountyMultiplier, 2, "new multiplier");
        assertEq(c.oracleFee, 7e17, "new fee");
        assertEq(c.rubricHash, sha256("new rubric"), "new rubric");
        assertEq(c.rubricURI, "https://paper.example/new-rubric", "new rubric URI");
        assertEq(c.recordURI, "https://paper.example/new-record/", "new record URI");
        assertEq(c.intake, address(replacement), "new intake");
        OracleAttestation.Attestation memory a = _attestation(oldId, true);
        bytes memory callData = abi.encodeCall(desk.settle, (oldId, a, _signature(a)));
        vm.expectRevert(DisputeDesk.NotTheIntake.selector);
        replacement.rawCallback(address(desk), callData);
        callData = abi.encodeCall(desk.failure, (oldId, uint8(1), bytes32(0), uint16(0), uint16(0), bytes("")));
        vm.expectRevert(DisputeDesk.NotTheIntake.selector);
        replacement.rawCallback(address(desk), callData);
        a = _attestation(newId, true);
        callData = abi.encodeCall(desk.settle, (newId, a, _signature(a)));
        vm.expectRevert(DisputeDesk.NotTheIntake.selector);
        intake.rawCallback(address(desk), callData);
        _verdict(oldId, true);
        _verdict(newId, true);
        assertEq(token.balanceOf(alice), INITIAL_USER + 1e18, "old locked payout");
        assertEq(token.balanceOf(bob), INITIAL_USER + 4e18, "new locked payout");
        assertEq(token.balanceOf(address(intake)), 5e17, "old fee");
        assertEq(token.balanceOf(address(replacement)), 7e17, "new fee");
        _accounting(33e17, 0, 0);
    }

    function testFuzz_lockedRemainderForRejectedAndFailedAfterDialChanges(bool rejected) public {
        bytes32 id = _file(alice, claim);
        MockIntake replacement = new MockIntake();
        vm.startPrank(NEWSROOM);
        desk.setBond(7e18);
        desk.setBountyMultiplier(9);
        desk.setOracleFee(6e18);
        desk.setIntake(address(replacement));
        desk.setPaused(true);
        vm.stopPrank();
        if (rejected) _verdict(id, false);
        else intake.fail(id, 2);
        _accounting(INITIAL_POOL, 0, 0);
        assertEq(token.balanceOf(NEWSROOM), rejected ? 5e17 : 0, "locked owner remainder");
        assertEq(token.balanceOf(alice), INITIAL_USER - (rejected ? 1e18 : 5e17), "locked challenger remainder");
    }

    function test_onlyOwnerCanChangeEveryDialAndEachEmitsItsEvent() public {
        bytes[] memory calls = new bytes[](7);
        calls[0] = abi.encodeCall(desk.setBond, (2e18));
        calls[1] = abi.encodeCall(desk.setBountyMultiplier, (2));
        calls[2] = abi.encodeCall(desk.setOracleFee, (7e17));
        calls[3] = abi.encodeCall(desk.setRubric, (sha256("new"), "https://new.example/rubric"));
        calls[4] = abi.encodeCall(desk.setRecordURI, ("https://new.example/record"));
        calls[5] = abi.encodeCall(desk.setIntake, (bob));
        calls[6] = abi.encodeCall(desk.setPaused, (true));
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(alice);
            (bool ok, bytes memory result) = address(desk).call(calls[i]);
            assertTrue(!ok, "non-owner changed dial");
            assertEq(result, abi.encodeWithSelector(DisputeDesk.NotOwner.selector), "owner authorization error");
        }
        vm.startPrank(NEWSROOM);
        vm.expectEmit(false, false, false, true, address(desk));
        emit BondSet(2e18);
        desk.setBond(2e18);
        vm.expectEmit(false, false, false, true, address(desk));
        emit BountyMultiplierSet(2);
        desk.setBountyMultiplier(2);
        vm.expectEmit(false, false, false, true, address(desk));
        emit OracleFeeSet(7e17);
        desk.setOracleFee(7e17);
        vm.expectEmit(true, false, false, true, address(desk));
        emit RubricSet(sha256("new"), "https://new.example/rubric");
        desk.setRubric(sha256("new"), "https://new.example/rubric");
        vm.expectEmit(false, false, false, true, address(desk));
        emit RecordURISet("https://new.example/record");
        desk.setRecordURI("https://new.example/record");
        vm.expectEmit(true, false, false, true, address(desk));
        emit IntakeSet(bob);
        desk.setIntake(bob);
        vm.expectEmit(false, false, false, true, address(desk));
        emit PausedSet(true);
        desk.setPaused(true);
        vm.stopPrank();
    }

    function test_poolHasNoOwnerWithdrawalEscrowRescueCancelOrVerdictOverride() public {
        bytes32 id = _file(alice, claim);
        bytes[] memory calls = new bytes[](11);
        calls[0] = abi.encodeWithSignature("withdraw(uint256)", 1e18);
        calls[1] = abi.encodeWithSignature("withdrawPool(uint256)", 1e18);
        calls[2] = abi.encodeWithSignature("withdraw(address,address,uint256)", address(token), NEWSROOM, 1e18);
        calls[3] = abi.encodeWithSignature("rescueTokens(address,address,uint256)", address(token), NEWSROOM, 1e18);
        calls[4] = abi.encodeWithSignature("cancel(bytes32)", id);
        calls[5] = abi.encodeWithSignature("cancelChallenge(bytes32)", id);
        calls[6] = abi.encodeWithSignature("overrideVerdict(bytes32,bool)", id, true);
        calls[7] = abi.encodeWithSignature("setCooldown(uint256)", 0);
        calls[8] = abi.encodeWithSignature("transferOwnership(address)", alice);
        calls[9] = abi.encodeWithSignature("upgradeTo(address)", alice);
        calls[10] = abi.encodeWithSignature("setOracleSigner(address)", alice);
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(NEWSROOM);
            (bool ok,) = address(desk).call(calls[i]);
            assertTrue(!ok, "forbidden owner path succeeded");
        }
        _accounting(INITIAL_POOL, 15e17, 5e17);
        assertEq(token.balanceOf(NEWSROOM), 0, "owner drained value");
        assertEq(desk.owner(), NEWSROOM, "ownership changed");
        assertEq(uint256(desk.challenges(id).status), uint256(DisputeDesk.Status.Open), "owner settled request");
    }
}

contract DisputeDeskAdversarialTest is DeskFixture {
    function test_constructorRejectsZeroDependenciesOwnerRubricAndInvalidTerms() public {
        vm.expectRevert(DisputeDesk.InvalidAddress.selector);
        new DisputeDesk(address(0), address(intake), NEWSROOM, 1e18, 1, 5e17, RUBRIC);
        vm.expectRevert(DisputeDesk.InvalidAddress.selector);
        new DisputeDesk(address(token), address(0), NEWSROOM, 1e18, 1, 5e17, RUBRIC);
        vm.expectRevert(DisputeDesk.InvalidAddress.selector);
        new DisputeDesk(address(token), address(intake), address(0), 1e18, 1, 5e17, RUBRIC);
        vm.expectRevert(DisputeDesk.InvalidTerms.selector);
        new DisputeDesk(address(token), address(intake), NEWSROOM, 1e18, 1, 5e17, bytes32(0));
        vm.expectRevert(DisputeDesk.InvalidTerms.selector);
        new DisputeDesk(address(token), address(intake), NEWSROOM, 0, 1, 0, RUBRIC);
        vm.expectRevert(DisputeDesk.InvalidTerms.selector);
        new DisputeDesk(address(token), address(intake), NEWSROOM, 1, 1, 2, RUBRIC);
        vm.expectRevert(DisputeDesk.InvalidTerms.selector);
        new DisputeDesk(address(token), address(intake), NEWSROOM, 1, type(uint256).max, 0, RUBRIC);
    }

    function test_invalidDialChangesAreAtomic() public {
        uint256 overflowMultiplier = (type(uint256).max - 1e18) / 1e18 + 1;
        vm.startPrank(NEWSROOM);
        vm.expectRevert(DisputeDesk.InvalidTerms.selector);
        desk.setBond(0);
        vm.expectRevert(DisputeDesk.InvalidTerms.selector);
        desk.setBond(5e17 - 1);
        vm.expectRevert(DisputeDesk.InvalidTerms.selector);
        desk.setBond(type(uint256).max);
        vm.expectRevert(DisputeDesk.InvalidTerms.selector);
        desk.setBountyMultiplier(overflowMultiplier);
        vm.expectRevert(DisputeDesk.InvalidTerms.selector);
        desk.setOracleFee(1e18 + 1);
        vm.expectRevert(DisputeDesk.InvalidTerms.selector);
        desk.setRubric(bytes32(0), RUBRIC_URI);
        vm.expectRevert(DisputeDesk.InvalidAddress.selector);
        desk.setIntake(address(0));
        vm.expectRevert(DisputeDesk.InvalidAddress.selector);
        desk.setIntake(address(desk));
        vm.stopPrank();
        assertEq(desk.bond(), 1e18, "invalid bond persisted");
        assertEq(desk.bountyMultiplier(), 1, "invalid multiplier persisted");
        assertEq(desk.oracleFee(), 5e17, "invalid fee persisted");
        assertEq(desk.rubricHash(), RUBRIC, "invalid rubric persisted");
        assertEq(desk.intake(), address(intake), "invalid intake persisted");
        _assertPristineFiling();
    }

    function testFuzz_termsValidateTheExactArithmeticBoundary(uint128 rawBond) public {
        uint256 b = uint256(rawBond) + 1;
        uint256 maximum = (type(uint256).max - b) / b;
        vm.startPrank(NEWSROOM);
        desk.setOracleFee(0);
        desk.setBountyMultiplier(0);
        desk.setBond(b);
        desk.setBountyMultiplier(maximum);
        vm.expectRevert(DisputeDesk.InvalidTerms.selector);
        desk.setBountyMultiplier(maximum + 1);
        vm.stopPrank();
        assertEq(desk.bountyMultiplier(), maximum, "maximum valid multiplier changed");
        assertTrue(b * maximum <= type(uint256).max - b, "accepted terms overflow payout");
    }

    function test_allURIInputsRejectEmptyOversizedAndMalformedUTF8() public {
        bytes[] memory invalid = new bytes[](12);
        invalid[0] = "";
        invalid[1] = new bytes(501);
        invalid[2] = hex"80"; // orphan continuation
        invalid[3] = hex"c080"; // overlong NUL
        invalid[4] = hex"c2"; // truncated two-byte sequence
        invalid[5] = hex"e08080"; // overlong three-byte sequence
        invalid[6] = hex"eda080"; // UTF-16 surrogate
        invalid[7] = hex"e282"; // truncated three-byte sequence
        invalid[8] = hex"f0808080"; // overlong four-byte sequence
        invalid[9] = hex"f4908080"; // greater than U+10FFFF
        invalid[10] = hex"f5808080"; // invalid leading byte
        invalid[11] = hex"e241a0"; // invalid continuation
        for (uint256 i; i < invalid.length; ++i) {
            string memory uri = string(invalid[i]);
            vm.expectRevert(DisputeDesk.InvalidURI.selector);
            vm.prank(alice);
            desk.challenge(edition, claim, uri, evidence);
            vm.expectRevert(DisputeDesk.InvalidURI.selector);
            vm.prank(NEWSROOM);
            desk.setRubric(RUBRIC, uri);
            vm.expectRevert(DisputeDesk.InvalidURI.selector);
            vm.prank(NEWSROOM);
            desk.setRecordURI(uri);
        }
        _assertPristineFiling();
        assertEq(desk.rubricURI(), RUBRIC_URI, "invalid rubric URI persisted");
        assertEq(desk.recordURI(), RECORD_URI, "invalid record URI persisted");
    }

    function test_wrongChainAndIntakeWithoutCodeCannotTakeBond() public {
        vm.chainId(4663);
        vm.expectRevert(DisputeDesk.WrongChain.selector);
        _file(alice, claim);
        vm.chainId(1);
        vm.prank(NEWSROOM);
        desk.setIntake(bob);
        vm.expectRevert(DisputeDesk.InvalidAddress.selector);
        _file(alice, claim);
        _assertPristineFiling();
    }

    function test_missingApprovalOrBalanceRollsBackFiling() public {
        vm.prank(alice);
        token.approve(address(desk), 1e18 - 1);
        vm.expectRevert(DisputeDesk.TokenCallFailed.selector);
        _file(alice, claim);
        _assertPristineFiling();
        vm.startPrank(alice);
        token.approve(address(desk), type(uint256).max);
        token.transfer(bob, INITIAL_USER);
        vm.stopPrank();
        vm.expectRevert(DisputeDesk.TokenCallFailed.selector);
        _file(alice, claim);
        _accounting(INITIAL_POOL, 0, 0);
        assertEq(desk.openChallenges(alice), 0, "insufficient balance locked slot");
        assertEq(intake.nonce(), 0, "insufficient balance opened oracle request");
    }

    function test_falseMalformedAndRevertingTransfersCannotFundOrFile() public {
        for (uint8 i = 1; i <= 5; ++i) {
            if (i == 2) continue; // empty return is the supported optional-return ABI
            token.configure(0, i, 0, 0);
            vm.expectRevert(DisputeDesk.TokenCallFailed.selector);
            _file(alice, claim);
            vm.expectRevert(DisputeDesk.TokenCallFailed.selector);
            vm.prank(alice);
            desk.fundPool(1e18);
            _assertPristineFiling();
        }
        token.configure(0, 0, 0, 0);
        _file(alice, claim);
    }

    function test_deflationaryIncomingTransfersCannotOvercreditEscrowOrPool() public {
        token.configure(0, 0, 0, 1);
        vm.expectRevert(DisputeDesk.IncorrectTokenAmount.selector);
        _file(alice, claim);
        vm.expectRevert(DisputeDesk.IncorrectTokenAmount.selector);
        vm.prank(alice);
        desk.fundPool(1e18);
        _assertPristineFiling();
    }

    function test_failingApprovalsAndIntakeRequestRollBackEverything() public {
        token.configure(0, 0, 1, 0);
        vm.expectRevert(DisputeDesk.TokenCallFailed.selector);
        _file(alice, claim);
        _assertPristineFiling();
        token.configure(0, 0, 0, 0);
        intake.setReject(true);
        vm.expectRevert();
        _file(alice, claim);
        _assertPristineFiling();
        intake.setReject(false);
        intake.setFeeDiscount(1);
        vm.expectRevert(DisputeDesk.IncorrectTokenAmount.selector);
        _file(alice, claim);
        _assertPristineFiling();
    }

    function test_optionalReturnTokenAndForceApproveZeroResetAreSupported() public {
        token.setRequireZeroApproval(true);
        token.seedAllowance(address(desk), address(intake), 1);
        token.configure(2, 2, 2, 0);
        vm.prank(bob);
        desk.fundPool(7);
        bytes32 id = _file(alice, claim);
        assertEq(token.allowance(address(desk), address(intake)), 0, "optional-return approval left behind");
        _verdict(id, true);
        _accounting(3e18 + 7, 0, 0);
        assertEq(token.balanceOf(alice), INITIAL_USER + 1e18, "optional-return payout");
    }

    function test_zeroOrReusedIntakeIDsRollBackNewFilingIncludingAfterMigration() public {
        intake.setForcedId(true, bytes32(0));
        vm.expectRevert(DisputeDesk.InvalidRequestId.selector);
        _file(alice, claim);
        _assertPristineFiling();
        intake.setForcedId(false, bytes32(0));
        bytes32 id = _file(alice, claim);
        bytes32 another = sha256("another claim");
        intake.setForcedId(true, id);
        vm.expectRevert(DisputeDesk.InvalidRequestId.selector);
        _file(bob, another);
        assertEq(desk.challenges(id).challenger, alice, "collision overwrote pending challenge");
        intake.fail(id, 1);
        vm.expectRevert(DisputeDesk.InvalidRequestId.selector);
        _file(bob, another);
        MockIntake replacement = new MockIntake();
        replacement.setForcedId(true, id);
        vm.prank(NEWSROOM);
        desk.setIntake(address(replacement));
        vm.expectRevert(DisputeDesk.InvalidRequestId.selector);
        _file(bob, another);
        _accounting(INITIAL_POOL, 0, 0);
        assertEq(token.balanceOf(bob), INITIAL_USER, "ID collision took bond");
        assertEq(desk.openChallenges(bob), 0, "ID collision took slot");
        assertEq(token.balanceOf(address(intake)), 5e17, "ID collision paid additional fee");
        assertEq(token.balanceOf(address(replacement)), 0, "migration collision paid fee");
        assertEq(
            uint256(desk.challenges(id).status), uint256(DisputeDesk.Status.Failed), "collision reopened terminal ID"
        );
    }

    function testFuzz_failedPayoutRollsBackAllSettlementEffectsAndCanBeRetried(uint8 outcomeSeed) public {
        uint256 outcome = outcomeSeed % 3;
        bytes32 id = _file(alice, claim);
        OracleAttestation.Attestation memory a = _attestation(id, outcome == 0);
        bytes memory signature = _signature(a);
        token.configure(1, 0, 0, 0);
        vm.expectRevert(DisputeDesk.TokenCallFailed.selector);
        if (outcome < 2) intake.deliver(id, a, signature);
        else intake.fail(id, 1);
        _accounting(INITIAL_POOL, 15e17, 5e17);
        assertEq(desk.activeChallenge(claim), id, "failed transfer cleared active claim");
        assertEq(desk.openChallenges(alice), 1, "failed transfer released slot");
        assertEq(desk.cooldownUntil(claim), 0, "failed transfer imposed cooldown");
        assertTrue(!desk.consumed(a.requestId), "failed transfer consumed attestation");
        assertEq(uint256(desk.challenges(id).status), uint256(DisputeDesk.Status.Open), "failed transfer closed claim");
        token.configure(0, 0, 0, 0);
        // The mock permits a retry to check atomicity; this is not a claim that
        // the live oracle retries a delivery that failed.
        if (outcome < 2) intake.deliver(id, a, signature);
        else intake.fail(id, 1);
        _accounting(outcome == 0 ? 3e18 : INITIAL_POOL, 0, 0);
    }

    function test_reentrantFilingFundingAndSettlementDuringBondPullAreBlocked() public {
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(desk.challenge, (edition, claim, EVIDENCE_URI, evidence));
        calls[1] = abi.encodeCall(desk.fundPool, (0));
        calls[2] =
            abi.encodeCall(desk.failure, (intake.nextId(), uint8(1), bytes32(0), uint16(0), uint16(0), bytes("")));
        for (uint256 i; i < calls.length; ++i) {
            token.setHook(2, address(desk), calls[i]);
            bytes32 id = _file(alice, bytes32(i + 1));
            assertTrue(token.hookCalls() > 0, "hook was not exercised");
            assertTrue(!token.hookSucceeded(), "reentrant operation succeeded");
            assertEq(token.hookResult(), abi.encodeWithSelector(DisputeDesk.Reentrancy.selector), "filing guard");
            intake.fail(id, 1);
        }
        _accounting(INITIAL_POOL, 0, 0);
    }

    function test_intakeCannotSynchronouslySettleBeforeRequestIsRegistered() public {
        bytes32 predicted = intake.nextId();
        intake.setHook(
            address(desk),
            abi.encodeCall(
                desk.failure, (predicted, uint8(1), bytes32("body_refused"), uint16(0), uint16(0), bytes(""))
            )
        );
        bytes32 id = _file(alice, claim);
        assertEq(id, predicted, "mock ID prediction");
        assertTrue(!intake.hookSucceeded(), "synchronous callback succeeded");
        assertEq(
            intake.hookResult(), abi.encodeWithSelector(DisputeDesk.Reentrancy.selector), "synchronous callback guard"
        );
        _accounting(INITIAL_POOL, 15e17, 5e17);
        intake.fail(id, 1);
        _accounting(INITIAL_POOL, 0, 0);
    }

    function testFuzz_settlementEffectsPrecedeTransferAndGuardEveryValueEntry(uint8 outcomeSeed, uint8 entrySeed)
        public
    {
        bytes32 id = _file(alice, claim);
        bytes memory nested;
        uint256 entry = entrySeed % 3;
        if (entry == 0) nested = abi.encodeCall(desk.challenge, (edition, claim, EVIDENCE_URI, evidence));
        if (entry == 1) nested = abi.encodeCall(desk.fundPool, (0));
        if (entry == 2) {
            nested = abi.encodeCall(desk.failure, (id, uint8(1), bytes32(0), uint16(0), uint16(0), bytes("")));
        }
        token.setHook(1, address(desk), nested);
        token.observeSettlement(desk, id);
        // The observer reads an entire dynamic Challenge and persists hook
        // diagnostics inside transfer. Give this instrumentation unrestricted
        // gas; all ordinary MockIntake deliveries enforce the real 200k stipend.
        uint256 outcome = outcomeSeed % 3;
        OracleAttestation.Attestation memory a = _attestation(id, outcome == 0);
        bytes memory signature = _signature(a);
        vm.prank(address(intake));
        if (outcome < 2) desk.settle(id, a, signature);
        else desk.failure(id, 1, bytes32("body_refused"), 0, 0, "");
        assertTrue(token.sawSettlementEffects(), "payout happened before settlement effects");
        assertEq(token.hookCalls(), 1, "settlement hook not exercised exactly once");
        assertTrue(!token.hookSucceeded(), "nested value operation succeeded");
        assertEq(token.hookResult(), abi.encodeWithSelector(DisputeDesk.Reentrancy.selector), "settlement guard");
    }

    function test_fundPoolCannotBeReenteredToCreateUnbackedCredit() public {
        token.setHook(2, address(desk), abi.encodeCall(desk.fundPool, (1)));
        vm.prank(alice);
        desk.fundPool(1e18);
        assertTrue(!token.hookSucceeded(), "recursive funding succeeded");
        assertEq(token.hookResult(), abi.encodeWithSelector(DisputeDesk.Reentrancy.selector), "funding guard");
        _accounting(INITIAL_POOL + 1e18, 0, 0);
    }

    function test_zeroFeeZeroBountyCanFileAgainstEmptyPoolAndRefundFullBond() public {
        _replaceDesk(1, 0, 0, 0, 1);
        bytes32 id = _file(alice, claim);
        _accounting(0, 0, 1);
        _verdict(id, true);
        _accounting(0, 0, 0);
        assertEq(token.balanceOf(alice), 1, "zero bounty still returns full bond");
        assertEq(token.balanceOf(address(intake)), 0, "zero fee");
    }

    function test_feeEqualToBondLeavesNoEscrowAndFailureNeverSpendsPool() public {
        _replaceDesk(1, 0, 1, 1, 1);
        bytes32 id = _file(alice, claim);
        _accounting(1, 1, 0);
        intake.fail(id, 1);
        _accounting(1, 0, 0);
        assertEq(token.balanceOf(alice), 0, "fee-only failure has no refundable remainder");
        assertEq(token.balanceOf(NEWSROOM), 0, "fee-only failure must not pay owner");
    }

    function test_maximumUintBondWithZeroBountySettlesWithoutLosingWei() public {
        _replaceDesk(type(uint256).max, 0, 0, 0, type(uint256).max);
        bytes32 id = _file(alice, claim);
        _accounting(0, 0, type(uint256).max);
        _verdict(id, true);
        _accounting(0, 0, 0);
        assertEq(token.balanceOf(alice), type(uint256).max, "maximum bond payout");
    }

    function test_largestEvenPayoutDoesNotOverflow() public {
        uint256 b = type(uint256).max / 2;
        _replaceDesk(b, 1, 0, b, b);
        bytes32 id = _file(alice, claim);
        _accounting(b, b, b);
        _verdict(id, true);
        _accounting(0, 0, 0);
        assertEq(token.balanceOf(alice), type(uint256).max - 1, "maximum even payout");
    }

    function _replaceDesk(uint256 b, uint256 multiplier, uint256 fee, uint256 pool, uint256 wallet) private {
        token = new DeskToken();
        intake = new MockIntake();
        desk = new DisputeDesk(address(token), address(intake), NEWSROOM, b, multiplier, fee, RUBRIC);
        vm.startPrank(NEWSROOM);
        desk.setRubric(RUBRIC, RUBRIC_URI);
        desk.setRecordURI(RECORD_URI);
        desk.setPaused(false);
        vm.stopPrank();
        token.mint(address(this), pool);
        token.approve(address(desk), type(uint256).max);
        desk.fundPool(pool);
        token.mint(alice, wallet);
        vm.prank(alice);
        token.approve(address(desk), type(uint256).max);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_mixedTermsAndVerdictInterleavingsConserveEveryWei(
        uint96 rawBond,
        uint32 rawMultiplier,
        uint96 rawFee,
        uint256 orderAndOutcomes
    ) public {
        uint256[3] memory bonds;
        uint256[3] memory bounties;
        uint256[3] memory fees;
        uint256[3] memory order = [uint256(0), 1, 2];
        bytes32[3] memory ids;
        uint256 initialPool;
        uint256 initialWallet;
        for (uint256 i; i < 3; ++i) {
            bonds[i] = bounded(uint256(rawBond) + i, 1, 1e24);
            bounties[i] = bonds[i] * bounded(uint256(rawMultiplier) + i, 0, 20);
            fees[i] = uint256(rawFee) % (bonds[i] + 1);
            initialPool += bounties[i] + fees[i];
            initialWallet += bonds[i];
        }
        _replaceDesk(bonds[0], bounties[0] / bonds[0], fees[0], initialPool, initialWallet);
        uint256 pool = initialPool;
        uint256 reserved;
        uint256 escrow;
        uint256 wallet = initialWallet;
        uint256 ownerPaid;
        uint256 oraclePaid;
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(NEWSROOM);
            desk.setOracleFee(0);
            desk.setBountyMultiplier(0);
            desk.setBond(bonds[i]);
            desk.setBountyMultiplier(bounties[i] / bonds[i]);
            desk.setOracleFee(fees[i]);
            vm.stopPrank();
            ids[i] = _file(alice, bytes32(i + 1));
            reserved += bounties[i] + fees[i];
            escrow += bonds[i] - fees[i];
            wallet -= bonds[i];
            oraclePaid += fees[i];
            _accounting(pool, reserved, escrow);
        }
        // Fisher-Yates gives all six settlement orders; verdicts are independent
        // of order and all terms differ, exposing wrong-request accounting.
        for (uint256 i = 3; i > 1; --i) {
            uint256 j = orderAndOutcomes % i;
            orderAndOutcomes /= i;
            (order[i - 1], order[j]) = (order[j], order[i - 1]);
        }
        for (uint256 n; n < 3; ++n) {
            uint256 i = order[n];
            uint256 outcome = orderAndOutcomes % 3;
            orderAndOutcomes /= 3;
            uint256 reservation = bounties[i] + fees[i];
            uint256 remainder = bonds[i] - fees[i];
            reserved -= reservation;
            escrow -= remainder;
            if (outcome == 0) {
                pool -= reservation;
                wallet += bonds[i] + bounties[i];
            } else if (outcome == 1) {
                ownerPaid += remainder;
            } else {
                wallet += remainder;
            }
            _outcome(ids[i], outcome);
            _accounting(pool, reserved, escrow);
            assertEq(token.balanceOf(alice), wallet, "mixed terms: challenger balance");
            assertEq(token.balanceOf(NEWSROOM), ownerPaid, "mixed terms: owner balance");
            assertEq(token.balanceOf(address(intake)), oraclePaid, "mixed terms: oracle balance");
            assertEq(
                wallet + ownerPaid + oraclePaid + pool + escrow,
                initialWallet + initialPool,
                "mixed terms: total conservation"
            );
            assertEq(desk.openChallenges(alice), 2 - n, "mixed terms: open count");
            for (uint256 k = n + 1; k < 3; ++k) {
                assertEq(
                    uint256(desk.challenges(ids[order[k]]).status),
                    uint256(DisputeDesk.Status.Open),
                    "settled a different request"
                );
            }
        }
    }
}

/// @dev Independent state machine: its ledgers are advanced from inputs and the
/// binding money-flow rules, never copied back from the court after an action.
/// Unexpected call results set a sticky flag so invariant failures cannot be
/// hidden by Foundry's default handling of reverted handler calls.
contract DisputeDeskHandler is DeskAssertions {
    uint256 private constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;

    struct Filing {
        bytes32 id;
        bytes32 claim;
        bytes32 edition;
        bytes32 evidence;
        bytes32 rubric;
        address challenger;
        address intake;
        uint256 bond;
        uint256 multiplier;
        uint256 fee;
        uint256 filedAt;
        string rubricURI;
        string recordURI;
        uint8 status; // Open=0, Upheld=1, Rejected=2, Failed=3
    }
    DeskToken public immutable token;
    DisputeDesk public immutable desk;
    address public immutable owner;
    MockIntake[2] public intakes;
    address[4] public actors;
    Filing[] private filings;
    mapping(bytes32 => bytes32) public active;
    mapping(bytes32 => uint256) public cooldown;
    mapping(address => uint256) public counts;
    mapping(address => uint256) public wallets;
    mapping(address => uint256) public oracleReceipts;
    uint256 public pool;
    uint256 public reserved;
    uint256 public escrow;
    uint256 public surplus;
    uint256 public funded;
    uint256 public poolPaid;
    uint256 public ownerReceipts;
    uint256 public immutable supply;
    uint256 public currentBond;
    uint256 public currentMultiplier;
    uint256 public currentFee;
    bytes32 public currentRubric;
    string public currentRubricURI;
    string public currentRecordURI;
    uint256 public currentIntake;
    bool public isPaused;
    bool public unexpectedResult;
    uint256 public successfulFilings;
    uint256[3] public settlements;
    uint256 public blockedFilings;
    uint256 public replayAttempts;
    uint256 public spoofAttempts;
    string private constant EVIDENCE_URI = "https://evidence.example/invariant";

    constructor(DeskToken token_, DisputeDesk desk_, MockIntake first, MockIntake second, address[4] memory actors_) {
        token = token_;
        desk = desk_;
        owner = desk_.owner();
        actors = actors_;
        intakes[0] = first;
        intakes[1] = second;
        pool = desk_.poolBalance();
        funded = pool;
        supply = token_.totalSupply();
        currentBond = desk_.bond();
        currentMultiplier = desk_.bountyMultiplier();
        currentFee = desk_.oracleFee();
        currentRubric = desk_.rubricHash();
        currentRubricURI = desk_.rubricURI();
        currentRecordURI = desk_.recordURI();
        isPaused = desk_.paused();
        for (uint256 i; i < 4; ++i) {
            wallets[actors_[i]] = token_.balanceOf(actors_[i]);
        }
    }

    function file(uint256 userSeed, uint256 claimSeed, bool pinned) external {
        address who = actors[userSeed % 4];
        // A small shared claim universe deliberately generates duplicate claims,
        // cooldown collisions, and multiple challengers contesting the same text.
        bytes32 which = bytes32(claimSeed % 12 + 1);
        uint256 reservation = currentBond * currentMultiplier + currentFee;
        bytes4 expectedError;
        if (isPaused) expectedError = DisputeDesk.Paused.selector;
        else if (active[which] != bytes32(0)) expectedError = DisputeDesk.ClaimAlreadyOpen.selector;
        else if (block.timestamp < cooldown[which]) expectedError = DisputeDesk.ClaimInCooldown.selector;
        else if (counts[who] == 3) expectedError = DisputeDesk.TooManyOpenChallenges.selector;
        else if (pool - reserved < reservation) expectedError = DisputeDesk.InsufficientPool.selector;
        else if (wallets[who] < currentBond) expectedError = DisputeDesk.TokenCallFailed.selector;
        bytes32 ed = keccak256(abi.encode("edition", successfulFilings));
        bytes32 pin = pinned ? keccak256(abi.encode("evidence", successfulFilings)) : bytes32(0);
        bytes memory data = abi.encodeCall(desk.challenge, (ed, which, EVIDENCE_URI, pin));
        vm.prank(who);
        (bool ok, bytes memory result) = address(desk).call(data);
        if (expectedError != bytes4(0)) {
            if (ok || keccak256(result) != keccak256(abi.encodeWithSelector(expectedError))) unexpectedResult = true;
            ++blockedFilings;
            return;
        }
        if (!ok || result.length != 32) {
            unexpectedResult = true;
            return;
        }
        bytes32 id = abi.decode(result, (bytes32));
        if (id == bytes32(0)) {
            unexpectedResult = true;
            return;
        }
        filings.push(
            Filing(
                id,
                which,
                ed,
                pin,
                currentRubric,
                who,
                address(intakes[currentIntake]),
                currentBond,
                currentMultiplier,
                currentFee,
                block.timestamp,
                currentRubricURI,
                currentRecordURI,
                0
            )
        );
        active[which] = id;
        ++counts[who];
        ++successfulFilings;
        reserved += reservation;
        escrow += currentBond - currentFee;
        wallets[who] -= currentBond;
        oracleReceipts[address(intakes[currentIntake])] += currentFee;
    }

    function settle(uint256 requestSeed, uint8 outcomeSeed) external {
        if (filings.length == 0) return;
        _settle(requestSeed % filings.length, outcomeSeed % 3);
    }

    function _settle(uint256 index, uint256 outcome) private {
        Filing storage f = filings[index];
        bytes memory data = _settlementData(f, outcome);
        (bool ok, bytes memory result) =
            address(MockIntake(f.intake)).call(abi.encodeCall(MockIntake.rawCallback, (address(desk), data)));
        if (f.status != 0) {
            ++replayAttempts;
            if (ok || keccak256(result) != keccak256(abi.encodeWithSelector(DisputeDesk.NotOpen.selector))) {
                unexpectedResult = true;
            }
            return;
        }
        if (!ok) {
            unexpectedResult = true;
            return;
        }
        f.status = uint8(outcome + 1);
        active[f.claim] = bytes32(0);
        --counts[f.challenger];
        uint256 reservation = f.bond * f.multiplier + f.fee;
        uint256 remainder = f.bond - f.fee;
        reserved -= reservation;
        escrow -= remainder;
        if (outcome == 0) {
            pool -= reservation;
            poolPaid += reservation;
            wallets[f.challenger] += f.bond + f.bond * f.multiplier;
        } else if (outcome == 1) {
            ownerReceipts += remainder;
            cooldown[f.claim] = block.timestamp + 604800;
        } else {
            wallets[f.challenger] += remainder;
        }
        ++settlements[outcome];
    }

    function _settlementData(Filing storage f, uint256 outcome) private view returns (bytes memory) {
        if (outcome == 2) {
            return abi.encodeCall(desk.failure, (f.id, uint8(2), bytes32("disagreed"), uint16(2), uint16(5), bytes("")));
        }
        OracleAttestation.Attestation memory a;
        a.requestId = keccak256(abi.encode("invariant oracle UUID", f.id));
        a.chainId = 1;
        a.questionHash = keccak256(abi.encode("resolved question", f.id));
        a.answer = abi.encode(outcome == 0);
        a.panelSize = 5;
        a.quorum = 3;
        a.agreed = 3;
        a.fromBlock = 100;
        a.toBlock = 200;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 604800);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, desk.attestationDigest(a));
        return abi.encodeCall(desk.settle, (f.id, a, abi.encodePacked(r, s, v)));
    }

    function fund(uint256 userSeed, uint96 amountSeed) external {
        address who = actors[userSeed % 4];
        uint256 amount = uint256(amountSeed) % (3e18 + 1);
        if (amount > wallets[who]) amount = wallets[who];
        vm.prank(who);
        (bool ok,) = address(desk).call(abi.encodeCall(desk.fundPool, (amount)));
        if (!ok) {
            unexpectedResult = true;
            return;
        }
        wallets[who] -= amount;
        pool += amount;
        funded += amount;
    }

    function donate(uint256 userSeed, uint96 amountSeed) external {
        address who = actors[userSeed % 4];
        uint256 amount = uint256(amountSeed) % (1e18 + 1);
        if (amount > wallets[who]) amount = wallets[who];
        vm.prank(who);
        token.transfer(address(desk), amount);
        wallets[who] -= amount;
        surplus += amount;
    }

    function changeTerms(uint96 bondSeed, uint8 multiplierSeed, uint96 feeSeed, bool alternateURI) external {
        uint256 b = bounded(bondSeed, 1, 2e18);
        uint256 m = multiplierSeed % 5;
        uint256 f = uint256(feeSeed) % (b + 1);
        bytes32 rubric = keccak256(abi.encode("rubric", alternateURI));
        string memory rubricURI_ = alternateURI ? "https://paper.example/rubric-a" : "https://paper.example/rubric-b";
        string memory recordURI_ = alternateURI ? "https://paper.example/record-a" : "https://paper.example/record-b";
        bytes[] memory calls = new bytes[](7);
        calls[0] = abi.encodeCall(desk.setOracleFee, (0));
        calls[1] = abi.encodeCall(desk.setBountyMultiplier, (0));
        calls[2] = abi.encodeCall(desk.setBond, (b));
        calls[3] = abi.encodeCall(desk.setBountyMultiplier, (m));
        calls[4] = abi.encodeCall(desk.setOracleFee, (f));
        calls[5] = abi.encodeCall(desk.setRubric, (rubric, rubricURI_));
        calls[6] = abi.encodeCall(desk.setRecordURI, (recordURI_));
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(owner);
            (bool ok,) = address(desk).call(calls[i]);
            if (!ok) unexpectedResult = true;
        }
        currentBond = b;
        currentMultiplier = m;
        currentFee = f;
        currentRubric = rubric;
        currentRubricURI = rubricURI_;
        currentRecordURI = recordURI_;
    }

    function migrate(bool second) external {
        uint256 next = second ? 1 : 0;
        vm.prank(owner);
        (bool ok,) = address(desk).call(abi.encodeCall(desk.setIntake, (address(intakes[next]))));
        if (!ok) {
            unexpectedResult = true;
            return;
        }
        currentIntake = next;
    }

    function pause(bool value) external {
        vm.prank(owner);
        (bool ok,) = address(desk).call(abi.encodeCall(desk.setPaused, (value)));
        if (!ok) {
            unexpectedResult = true;
            return;
        }
        isPaused = value;
    }

    function elapse(uint32 secondsSeed) external {
        vm.warp(block.timestamp + uint256(secondsSeed) % (8 days + 1));
    }

    function spoof(uint256 requestSeed, bool useWrongIntake, uint8 outcomeSeed) external {
        if (filings.length == 0) return;
        Filing storage f = filings[requestSeed % filings.length];
        bytes memory data = _settlementData(f, outcomeSeed % 3);
        address attacker =
            useWrongIntake ? (f.intake == address(intakes[0]) ? address(intakes[1]) : address(intakes[0])) : owner;
        vm.prank(attacker);
        (bool ok, bytes memory result) = address(desk).call(data);
        ++spoofAttempts;
        if (ok || keccak256(result) != keccak256(abi.encodeWithSelector(DisputeDesk.NotTheIntake.selector))) {
            unexpectedResult = true;
        }
    }

    function closeAll() external {
        for (uint256 i; i < filings.length; ++i) {
            if (filings[i].status == 0) _settle(i, i % 3);
        }
    }

    function checkAccounting() external view {
        assertTrue(!unexpectedResult, "handler observed unexpected success/revert");
        assertEq(desk.poolBalance(), pool, "model pool");
        assertEq(desk.reservedBounties(), reserved, "model reservations");
        assertEq(desk.escrowedBonds(), escrow, "model escrow");
        assertEq(pool + poolPaid, funded, "pool one-way valve: only funding minus upheld payouts");
        assertTrue(reserved <= pool, "pool cannot pay all open bounties");
        assertEq(token.balanceOf(address(desk)), pool + escrow + surplus, "court holds every owed wei plus donations");
        assertEq(token.balanceOf(owner), ownerReceipts, "owner receives only rejected remainders");
        uint256 accounted = pool + escrow + surplus + ownerReceipts;
        for (uint256 i; i < 4; ++i) {
            assertEq(token.balanceOf(actors[i]), wallets[actors[i]], "challenger ledger");
            accounted += wallets[actors[i]];
        }
        for (uint256 i; i < 2; ++i) {
            address oracle = address(intakes[i]);
            assertEq(token.balanceOf(oracle), oracleReceipts[oracle], "locked oracle fee ledger");
            assertEq(token.allowance(address(desk), oracle), 0, "intake retains spending power");
            accounted += oracleReceipts[oracle];
        }
        assertEq(token.totalSupply(), supply, "supply unexpectedly changed");
        assertEq(accounted, supply, "global conservation of every wei");
    }

    function checkRequestsAndTerms() external view {
        uint256 openEscrow;
        uint256 openReserved;
        uint256[4] memory openCounts;
        for (uint256 i; i < filings.length; ++i) {
            Filing storage f = filings[i];
            DisputeDesk.Challenge memory c = desk.challenges(f.id);
            assertEq(c.challenger, f.challenger, "challenger identity changed");
            assertEq(c.requestId, f.id, "request ID changed");
            assertEq(c.claimHash, f.claim, "claim changed");
            assertEq(c.editionHash, f.edition, "edition changed");
            assertEq(c.evidenceURI, EVIDENCE_URI, "evidence URI changed");
            assertEq(c.evidenceHash, f.evidence, "evidence pin changed");
            assertEq(c.bond, f.bond, "locked bond changed");
            assertEq(c.bounty, f.bond * f.multiplier, "locked bounty changed");
            assertEq(c.bountyMultiplier, f.multiplier, "locked multiplier changed");
            assertEq(c.oracleFee, f.fee, "locked fee changed");
            assertEq(c.intake, f.intake, "locked intake changed");
            assertEq(c.rubricHash, f.rubric, "locked rubric hash changed");
            assertEq(c.rubricURI, f.rubricURI, "locked rubric URI changed");
            assertEq(c.recordURI, f.recordURI, "locked record URI changed");
            assertEq(c.filedAt, f.filedAt, "filing time changed");
            assertEq(uint256(c.status), f.status, "terminal status changed or wrong request settled");
            bool wasConsumed = desk.consumed(keccak256(abi.encode("invariant oracle UUID", f.id)));
            assertTrue(
                wasConsumed == (f.status == 1 || f.status == 2), "attestation consumption disagrees with verdict"
            );
            if (f.status == 0) {
                assertEq(active[f.claim], f.id, "more than one active challenge for claim");
                openEscrow += f.bond - f.fee;
                openReserved += f.bond * f.multiplier + f.fee;
                for (uint256 j; j < 4; ++j) {
                    if (f.challenger == actors[j]) ++openCounts[j];
                }
            }
        }
        assertEq(openEscrow, escrow, "sum of live escrows");
        assertEq(openReserved, reserved, "sum of live reservations");
        for (uint256 i; i < 4; ++i) {
            assertEq(desk.openChallenges(actors[i]), openCounts[i], "per-actor count disagrees with actual open set");
            assertEq(openCounts[i], counts[actors[i]], "model open count");
            assertTrue(openCounts[i] <= 3, "three-open limit exceeded");
        }
        for (uint256 i = 1; i <= 12; ++i) {
            assertEq(desk.activeChallenge(bytes32(i)), active[bytes32(i)], "active claim index");
            assertEq(desk.cooldownUntil(bytes32(i)), cooldown[bytes32(i)], "cooldown differs from rejection history");
        }
        assertEq(desk.bond(), currentBond, "current bond");
        assertEq(desk.bountyMultiplier(), currentMultiplier, "current multiplier");
        assertEq(desk.oracleFee(), currentFee, "current fee");
        assertEq(desk.rubricHash(), currentRubric, "current rubric");
        assertEq(desk.rubricURI(), currentRubricURI, "current rubric URI");
        assertEq(desk.recordURI(), currentRecordURI, "current record URI");
        assertEq(desk.intake(), address(intakes[currentIntake]), "current intake");
        assertTrue(desk.paused() == isPaused, "pause model");
        assertEq(desk.owner(), owner, "owner immutable");
        assertEq(desk.imdToken(), address(token), "token immutable");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
contract DisputeDeskInvariantTest is DeskFixture {
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }
    DisputeDeskHandler private handler;

    function setUp() public override {
        super.setUp();
        address[4] memory actors = [
            alice,
            bob,
            address(uint160(uint256(keccak256("invariant challenger Carol")))),
            address(uint160(uint256(keccak256("invariant challenger Dan"))))
        ];
        for (uint256 i = 2; i < 4; ++i) {
            token.mint(actors[i], INITIAL_USER);
            vm.prank(actors[i]);
            token.approve(address(desk), type(uint256).max);
        }
        handler = new DisputeDeskHandler(token, desk, intake, new MockIntake(), actors);
    }

    // Foundry's invariant target ABI, normally supplied by StdInvariant. Explicit
    // selectors keep closeAll and the observation helpers out of random actions.
    function targetContracts() external view returns (address[] memory addresses) {
        addresses = new address[](1);
        addresses[0] = address(handler);
    }

    function targetSelectors() external view returns (FuzzSelector[] memory targets) {
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.file.selector;
        selectors[1] = handler.settle.selector;
        selectors[2] = handler.fund.selector;
        selectors[3] = handler.donate.selector;
        selectors[4] = handler.changeTerms.selector;
        selectors[5] = handler.migrate.selector;
        selectors[6] = handler.pause.selector;
        selectors[7] = handler.elapse.selector;
        selectors[8] = handler.spoof.selector;
        selectors[9] = handler.file.selector; // weight filing to build overlapping requests
        targets = new FuzzSelector[](1);
        targets[0] = FuzzSelector(address(handler), selectors);
    }

    function invariant_allCustodyMatchesIndependentLedgers() public view {
        handler.checkAccounting();
    }

    function invariant_everyRequestHasLockedTermsAndConsistentLifecycle() public view {
        handler.checkRequestsAndTerms();
    }

    function afterInvariant() public {
        // A sequence may end paused or with a different current intake. Drain
        // every outstanding obligation through its original intake, then check
        // that no escrow or reservation is orphaned.
        handler.closeAll();
        handler.checkAccounting();
        handler.checkRequestsAndTerms();
        assertEq(desk.escrowedBonds(), 0, "escrow stranded after all verdicts");
        assertEq(desk.reservedBounties(), 0, "reservation stranded after all verdicts");
    }

    function test_handlerExercisesAllPathsAndRejectsReplayAndSpoof() public {
        // Deterministic non-vacuity check alongside random sequences.
        handler.file(0, 0, true);
        handler.file(0, 0, false);
        handler.file(1, 1, false);
        handler.file(2, 2, true);
        handler.changeTerms(2e18 - 1, 3, 7e17, true);
        handler.migrate(true);
        handler.pause(true);
        handler.file(3, 3, true);
        handler.spoof(0, true, 0);
        handler.spoof(1, false, 2);
        handler.settle(0, 0);
        handler.settle(1, 1);
        handler.settle(2, 2);
        handler.settle(0, 2);
        handler.fund(3, 3e18);
        handler.donate(3, 1e18);
        handler.pause(false);
        handler.elapse(604800);
        handler.file(3, 1, true);
        handler.closeAll();
        handler.checkAccounting();
        handler.checkRequestsAndTerms();
        assertTrue(handler.successfulFilings() >= 3, "handler never filed");
        for (uint256 i; i < 3; ++i) {
            assertTrue(handler.settlements(i) > 0, "handler omitted a settlement path");
        }
        assertTrue(handler.blockedFilings() > 0, "handler never tested blocked filing");
        assertTrue(handler.replayAttempts() > 0, "handler never tested replay");
        assertTrue(handler.spoofAttempts() > 0, "handler never tested spoofing");
    }
}

contract DisputeDeskOracleTest is DeskFixture {
    string private constant BURDEN =
        "The bond carries the burden of proof. A genuinely conflicting, unverifiable or silent record means REJECTED: a tie goes to the text.";
    string private constant PIN_RULE =
        ". If a nonzero hash is given and the sha256 of the material fetched at the evidence URI does not match it, treat the challenger evidence as absent.";
    string private constant MALFORMED = "A claim whose exact text cannot be located in the edition means REJECTED.";

    function _question(
        bytes32 ed,
        bytes32 cl,
        string memory ev,
        string memory rubricURI_,
        bytes32 rubricHash_,
        string memory record
    ) private pure returns (string memory) {
        return string.concat(
            "Is the identified claim in the Open Interest edition with sha256 ",
            vm.toString(ed),
            " materially wrong, per the cited evidence? Judge by the rubric at ",
            rubricURI_,
            " (sha256 ",
            vm.toString(rubricHash_),
            "). The claim is the passage with sha256 ",
            vm.toString(cl),
            ". Challenger evidence: ",
            ev,
            ". The edition's verbatim record is published under ",
            record,
            ". Answer true for UPHELD, false for REJECTED."
        );
    }

    function _assertBody(bytes32 id, string memory expectedQuestion, bytes32 pin) private view {
        string memory body = string(intake.request(id).body);
        // These cheatcodes use an independent JSON parser, not a Solidity copy of
        // the implementation's encoder. Key counts also reject injected members.
        assertEq(vm.parseJsonKeys(body, "$").length, 11, "unexpected top-level JSON keys");
        assertEq(vm.parseJsonUint(body, ".v"), 1, "body version");
        assertEq(vm.parseJsonString(body, ".question"), expectedQuestion, "decoded question differs from template");
        assertEq(vm.parseJsonUint(body, ".chainId"), 1, "question chain");
        assertEq(vm.parseJsonKeys(body, ".window").length, 1, "unexpected window keys");
        assertEq(vm.parseJsonUint(body, ".window.hours"), 72, "relative window");
        assertEq(vm.parseJsonString(body, ".answerType"), "bool", "answer type");
        assertEq(vm.parseJsonString(body, ".evidence"), "panel", "evidence mode");
        assertEq(vm.parseJsonUint(body, ".panelSize"), 5, "body panel size");
        assertEq(vm.parseJsonUint(body, ".quorum"), 3, "body quorum");
        assertEq(vm.parseJsonUint(body, ".validForSeconds"), 604800, "body validity");
        assertEq(vm.parseJsonKeys(body, ".definitions").length, 3, "definition keys");
        assertEq(vm.parseJsonString(body, ".definitions.burden"), BURDEN, "burden definition");
        assertEq(
            vm.parseJsonString(body, ".definitions.evidencehash"),
            string.concat(pin == bytes32(0) ? "unpinned" : vm.toString(pin), PIN_RULE),
            "evidence pin definition"
        );
        assertEq(vm.parseJsonString(body, ".definitions.malformed"), MALFORMED, "malformed definition");
        assertEq(vm.parseJsonKeys(body, ".consumer").length, 2, "consumer keys");
        assertEq(vm.parseJsonUint(body, ".consumer.chainId"), 1, "consumer chain");
        assertEq(
            vm.parseJsonString(body, ".consumer.verifyingContract"),
            lowercase(vm.toString(address(desk))),
            "verifying contract must be consumer in lowercase"
        );
        assertTrue(bytes(expectedQuestion).length <= 2000, "question exceeds protocol limit");
        assertTrue(bytes(body).length <= 16_384, "body exceeds protocol limit");
    }

    function test_pinnedOracleBodyIsExactCompactTemplateAndParsesAsJSON() public {
        bytes32 id = _file(alice, claim);
        string memory question = _question(edition, claim, EVIDENCE_URI, RUBRIC_URI, RUBRIC, RECORD_URI);
        _assertBody(id, question, evidence);
        bytes memory expected = abi.encodePacked(
            '{"v":1,"question":"',
            question,
            '","chainId":1,"window":{"hours":72},"answerType":"bool","evidence":"panel","panelSize":5,"quorum":3,"validForSeconds":604800,"definitions":{"burden":"',
            BURDEN,
            '","evidencehash":"',
            vm.toString(evidence),
            PIN_RULE,
            '","malformed":"',
            MALFORMED,
            '"},"consumer":{"chainId":1,"verifyingContract":"',
            lowercase(vm.toString(address(desk))),
            '"}}'
        );
        assertEq(intake.request(id).body, expected, "wire body is not exact compact template");
    }

    function test_zeroEvidenceHashIsExplicitlyUnpinned() public {
        vm.prank(alice);
        bytes32 id = desk.challenge(edition, claim, EVIDENCE_URI, bytes32(0));
        _assertBody(id, _question(edition, claim, EVIDENCE_URI, RUBRIC_URI, RUBRIC, RECORD_URI), bytes32(0));
        assertEq(desk.challenges(id).evidenceHash, bytes32(0), "optional pin stored");
    }

    function test_jsonPreservesPercentEncodedTextAndRejectsRawInjection() public {
        bytes memory controls = new bytes(32);
        for (uint256 i; i < 32; ++i) {
            controls[i] = bytes1(uint8(i));
        }
        string memory uri = string(
            bytes.concat(
                bytes('https://evidence.example/"\\'), controls, bytes(unicode"/café/漢字/😀/\"},\"panelSize\":2")
            )
        );
        string memory rubricURI_ = 'https://rubric.example/"\\\n\r\t';
        string memory record = string(bytes.concat(bytes('https://record.example/"\\'), hex"080c"));
        // URI validation rejects raw prose/JSON delimiters before spending a fee.
        // The same bytes may be carried safely in a percent-encoded path.
        vm.expectRevert(DisputeDesk.InvalidURI.selector);
        vm.prank(alice);
        desk.challenge(edition, claim, uri, evidence);
        vm.expectRevert(DisputeDesk.InvalidURI.selector);
        vm.prank(NEWSROOM);
        desk.setRubric(RUBRIC, rubricURI_);
        vm.expectRevert(DisputeDesk.InvalidURI.selector);
        vm.prank(NEWSROOM);
        desk.setRecordURI(record);
        _assertPristineFiling();
        assertEq(desk.rubricURI(), RUBRIC_URI, "raw rubric injection persisted");
        assertEq(desk.recordURI(), RECORD_URI, "raw record injection persisted");
        uri = string.concat("https://evidence.example/", _percentEncode(bytes(uri)));
        rubricURI_ = string.concat("https://rubric.example/", _percentEncode(bytes(rubricURI_)));
        record = string.concat("https://record.example/", _percentEncode(bytes(record)));
        vm.startPrank(NEWSROOM);
        desk.setRubric(RUBRIC, rubricURI_);
        desk.setRecordURI(record);
        vm.stopPrank();
        vm.prank(alice);
        bytes32 id = desk.challenge(edition, claim, uri, evidence);
        _assertBody(id, _question(edition, claim, uri, rubricURI_, RUBRIC, record), evidence);
        assertEq(desk.challenges(id).evidenceURI, uri, "URI must survive round trip");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_jsonRoundTripForPercentEncodedURIsAndArbitraryHashes(
        bytes memory seed,
        bytes32 ed,
        bytes32 cl,
        bytes32 pin
    ) public {
        // Each arbitrary byte needs three URI characters; leave room for the scheme/host.
        uint256 length = seed.length > 150 ? 150 : seed.length;
        bytes memory uriBytes = new bytes(length);
        for (uint256 i; i < length; ++i) {
            uriBytes[i] = seed[i];
        }
        string memory uri = string.concat("https://evidence.example/", _percentEncode(uriBytes));
        vm.prank(alice);
        bytes32 id = desk.challenge(ed, cl, uri, pin);
        _assertBody(id, _question(ed, cl, uri, RUBRIC_URI, RUBRIC, RECORD_URI), pin);
    }

    function _percentEncode(bytes memory raw) private pure returns (string memory) {
        bytes16 digits = "0123456789ABCDEF";
        bytes memory encoded = new bytes(raw.length * 3);
        for (uint256 i; i < raw.length; ++i) {
            encoded[3 * i] = "%";
            encoded[3 * i + 1] = digits[uint8(raw[i]) >> 4];
            encoded[3 * i + 2] = digits[uint8(raw[i]) & 15];
        }
        return string(encoded);
    }

    function test_maximumLengthURIsKeepQuestionAndBodyWithinOracleLimits() public {
        bytes memory raw = new bytes(500);
        bytes memory prefix = bytes("https://evidence.example/");
        for (uint256 i; i < raw.length; ++i) {
            raw[i] = i < prefix.length ? prefix[i] : bytes1("a");
        }
        string memory uri = string(raw);
        vm.startPrank(NEWSROOM);
        desk.setRubric(RUBRIC, uri);
        desk.setRecordURI(uri);
        vm.stopPrank();
        vm.prank(alice);
        bytes32 id = desk.challenge(edition, claim, uri, evidence);
        _assertBody(id, _question(edition, claim, uri, uri, RUBRIC, uri), evidence);
    }

    function test_protocolVectorDigestAndSignatureMatchCanonicalDomain() public {
        // Unmodified network conformance vector. This catches a mutually
        // consistent but incorrect test/implementation EIP-712 encoding.
        address vectorConsumer = 0x0000000000000000000000000000000000002748;
        vm.etch(vectorConsumer, address(desk).code);
        vm.chainId(11155111);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        OracleAttestation.Attestation memory a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: 5,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: 1800000000,
            expiresAt: 1800003600
        });
        bytes32 digest = DisputeDesk(vectorConsumer).attestationDigest(a);
        assertEq(
            digest,
            0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c,
            "digest differs from pinned protocol vector"
        );
        bytes memory sig =
            hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        assertEq(ecrecover(digest, v, r, s), 0x70997970C51812dc3A010C7d01b50e0d17dc79C8, "protocol signature recovery");
        assertTrue(desk.attestationDigest(a) != digest, "signature must be bound to consumer");
        vm.chainId(1);
        assertTrue(
            DisputeDesk(vectorConsumer).attestationDigest(a) != digest, "signature must be bound to domain chain"
        );
    }

    function test_callbackSelectorsMatchCanonicalProtocolABI() public view {
        assertEq(
            bytes32(desk.settle.selector),
            bytes32(
                bytes4(
                    keccak256(
                        "settle(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)"
                    )
                )
            ),
            "result callback ABI"
        );
        assertEq(
            bytes32(desk.failure.selector),
            bytes32(bytes4(keccak256("failure(bytes32,uint8,bytes32,uint16,uint16,bytes)"))),
            "failure callback ABI"
        );
    }

    function test_spoofedCallbacksFromOwnerChallengerAndStrangerAreRefused() public {
        bytes32 id = _file(alice, claim);
        OracleAttestation.Attestation memory a = _attestation(id, true);
        bytes memory signature = _signature(a);
        address[3] memory senders = [NEWSROOM, alice, bob];
        for (uint256 i; i < senders.length; ++i) {
            vm.expectRevert(DisputeDesk.NotTheIntake.selector);
            vm.prank(senders[i]);
            desk.settle(id, a, signature);
            vm.expectRevert(DisputeDesk.NotTheIntake.selector);
            vm.prank(senders[i]);
            desk.failure(id, 1, bytes32("body_refused"), 0, 0, "");
        }
        _accounting(INITIAL_POOL, 15e17, 5e17);
        assertTrue(!desk.consumed(a.requestId), "spoof must not consume UUID");
    }

    function test_unknownRequestCannotSettleOrRefundEvenFromTrustedIntake() public {
        bytes32 id = _file(alice, claim);
        bytes32 unknown = keccak256("unknown request");
        OracleAttestation.Attestation memory a = _attestation(id, true);
        bytes memory data = abi.encodeCall(desk.settle, (unknown, a, _signature(a)));
        vm.expectRevert(DisputeDesk.InvalidRequestId.selector);
        intake.rawCallback(address(desk), data);
        data =
            abi.encodeCall(desk.failure, (unknown, uint8(1), bytes32("body_refused"), uint16(0), uint16(0), bytes("")));
        vm.expectRevert(DisputeDesk.InvalidRequestId.selector);
        intake.rawCallback(address(desk), data);
        data = abi.encodeCall(desk.failure, (bytes32(0), uint8(1), bytes32(0), uint16(0), uint16(0), bytes("")));
        vm.expectRevert(DisputeDesk.InvalidRequestId.selector);
        intake.rawCallback(address(desk), data);
        _accounting(INITIAL_POOL, 15e17, 5e17);
    }

    function test_oracleUUIDCannotBeReusedForAnotherOpenChallenge() public {
        bytes32 first = _file(alice, claim);
        bytes32 second = _file(bob, sha256("second"));
        OracleAttestation.Attestation memory a = _attestation(first, true);
        bytes memory signature = _signature(a);
        intake.deliver(first, a, signature);
        assertTrue(desk.consumed(a.requestId), "oracle UUID must be consumed");
        vm.expectRevert(DisputeDesk.AlreadyConsumed.selector);
        intake.deliver(second, a, signature);
        assertEq(
            uint256(desk.challenges(second).status), uint256(DisputeDesk.Status.Open), "replay closed another challenge"
        );
        _accounting(3e18, 15e17, 5e17);
        _verdict(second, false);
    }

    function test_signedButInvalidAttestationsAreRejectedWithoutChangingAccounting() public {
        bytes32 id = _file(alice, claim);
        for (uint256 i; i < 13; ++i) {
            OracleAttestation.Attestation memory a = _attestation(id, true);
            if (i == 0) a.chainId = 4663;
            if (i == 1) a.answerType = 3;
            if (i == 2) a.answer = hex"01";
            if (i == 3) a.requestId = bytes32(0);
            if (i == 4) a.panelSize = 4;
            if (i == 5) a.quorum = 2;
            if (i == 6) a.agreed = 2;
            if (i == 7) a.agreed = 6;
            if (i == 8) a.fromBlock = 201;
            if (i == 9) a.expiresAt = a.issuedAt - 1;
            if (i == 10) {
                a.issuedAt -= 2;
                a.expiresAt = uint64(block.timestamp - 1);
            }
            if (i == 11) a.issuedAt = uint64(block.timestamp + 301);
            if (i == 12) a.issuedAt = uint64(block.timestamp - 301);
            bytes memory signature = _signature(a);
            vm.expectRevert(DisputeDesk.InvalidAttestation.selector);
            intake.deliver(id, a, signature);
            assertTrue(!desk.consumed(a.requestId), "invalid attestation consumed UUID");
            _accounting(INITIAL_POOL, 15e17, 5e17);
        }
        _verdict(id, true);
    }

    function test_nonCanonicalBooleanIsRejectedEvenWithValidSignature() public {
        bytes32 id = _file(alice, claim);
        OracleAttestation.Attestation memory a = _attestation(id, true);
        a.answer = abi.encode(uint256(2));
        bytes memory signature = _signature(a);
        vm.expectRevert();
        intake.deliver(id, a, signature);
        assertTrue(!desk.consumed(a.requestId), "invalid bool consumed");
        _accounting(INITIAL_POOL, 15e17, 5e17);
    }

    function test_validityBoundariesIncludeExpiryAndFiveMinuteTolerance() public {
        bytes32[3] memory ids;
        for (uint256 i; i < 3; ++i) {
            ids[i] = _file(alice, bytes32(i + 1));
        }
        for (uint256 i; i < 3; ++i) {
            OracleAttestation.Attestation memory a = _attestation(ids[i], false);
            if (i == 0) a.expiresAt = uint64(block.timestamp);
            if (i == 1) a.issuedAt = uint64(block.timestamp + 300);
            if (i == 2) a.issuedAt = uint64(block.timestamp - 300);
            intake.deliver(ids[i], a, _signature(a));
        }
        _accounting(INITIAL_POOL, 0, 0);
        assertEq(token.balanceOf(NEWSROOM), 15e17, "boundary rejections paid");
    }

    function test_tamperedSignatureAndWrongConsumerDomainCannotSettle() public {
        bytes32 id = _file(alice, claim);
        OracleAttestation.Attestation memory a = _attestation(id, false);
        bytes memory signature = _signature(a);
        a.answer = abi.encode(true);
        vm.expectRevert(DisputeDesk.BadSignature.selector);
        intake.deliver(id, a, signature);
        DisputeDesk other = new DisputeDesk(address(token), address(intake), NEWSROOM, 1e18, 1, 5e17, RUBRIC);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, other.attestationDigest(a));
        signature = abi.encodePacked(r, s, v);
        vm.expectRevert(DisputeDesk.BadSignature.selector);
        intake.deliver(id, a, signature);
        vm.expectRevert(DisputeDesk.BadSignature.selector);
        intake.deliver(id, a, "");
        _accounting(INITIAL_POOL, 15e17, 5e17);
        _verdict(id, true);
    }

    function test_EOASignerAcceptsValidUpheldVerdict() public {
        _assertEOASettlement(true);
    }

    function test_EOASignerAcceptsValidRejectedVerdict() public {
        _assertEOASettlement(false);
    }

    function _assertEOASettlement(bool upheld) private {
        _useEOASigner();
        bytes32 id = _file(alice, claim);
        OracleAttestation.Attestation memory a = _attestation(id, upheld);
        bytes memory signature = _signature(a);
        assertEq(signature.length, 65, "canonical ECDSA signature length");

        // A changed answer must still fail: replacing the trusted address must
        // not bypass verification or let the ERC-1271 fixture accept the result.
        a.answer = abi.encode(!upheld);
        vm.expectRevert(DisputeDesk.BadSignature.selector);
        intake.deliver(id, a, signature);
        assertTrue(!desk.consumed(a.requestId), "tampered ECDSA verdict consumed UUID");
        _accounting(INITIAL_POOL, 15e17, 5e17);

        a.answer = abi.encode(upheld);
        // MockIntake uses the recorded callback selector and a 200,000-gas cap.
        intake.deliver(id, a, signature);
        _closed(id, upheld ? DisputeDesk.Status.Upheld : DisputeDesk.Status.Rejected);
        assertTrue(desk.consumed(a.requestId), "ECDSA verdict did not consume UUID");
        _accounting(upheld ? 3e18 : INITIAL_POOL, 0, 0);
        assertEq(token.balanceOf(alice), upheld ? INITIAL_USER + 1e18 : INITIAL_USER - 1e18, "EOA challenger payout");
        assertEq(token.balanceOf(NEWSROOM), upheld ? 0 : 5e17, "EOA owner payout");
        assertEq(token.balanceOf(address(intake)), 5e17, "EOA oracle fee remains spent");
        assertEq(desk.cooldownUntil(claim), upheld ? 0 : block.timestamp + 604800, "EOA verdict cooldown");
        vm.expectRevert(DisputeDesk.NotOpen.selector);
        intake.deliver(id, a, signature);
    }

    function _useEOASigner() private {
        // The mainnet signer's private key is unavailable. Change only PUSH20
        // operands equal to its constant in this test instance's runtime. All
        // opcodes, storage, immutables and signature checks remain as compiled.
        // No precompile is mocked and neither signer address has ERC-1271 code.
        address originalSigner = desk.oracleSigner();
        address testSigner = vm.addr(SIGNER_KEY);
        vm.etch(originalSigner, "");
        assertEq(originalSigner.code.length, 0, "ERC-1271 fixture must be removed");
        assertEq(testSigner.code.length, 0, "test signer must be an EOA");
        bytes memory runtime = address(desk).code;
        uint256 replacements;
        for (uint256 offset; offset < runtime.length; ++offset) {
            uint8 opcode = uint8(runtime[offset]);
            if (opcode < 0x60 || opcode > 0x7f) continue;
            uint256 width = opcode - 0x5f;
            if (width == 20 && offset + width < runtime.length) {
                bytes20 operand;
                assembly ("memory-safe") {
                    operand := mload(add(add(runtime, 33), offset))
                }
                if (operand == bytes20(originalSigner)) {
                    for (uint256 j; j < 20; ++j) {
                        runtime[offset + 1 + j] = bytes20(testSigner)[j];
                    }
                    ++replacements;
                }
            }
            offset += width; // Skip PUSH data so it cannot be mistaken for opcodes.
        }
        assertTrue(replacements > 0, "no signer PUSH20 found in runtime");
        vm.etch(address(desk), runtime);
        assertEq(desk.oracleSigner(), testSigner, "signer substitution failed");
    }

    function test_realEOASignerRejectsWrongKeyLengthHighSAndInvalidV() public {
        bytes32 id = _file(alice, claim);
        OracleAttestation.Attestation memory a = _attestation(id, true);
        bytes memory signature = _signature(a);
        vm.etch(desk.oracleSigner(), "");
        vm.expectRevert(DisputeDesk.BadSignature.selector);
        intake.deliver(id, a, signature);
        vm.expectRevert(DisputeDesk.BadSignature.selector);
        intake.deliver(id, a, "");
        signature = abi.encodePacked(bytes32(uint256(1)), bytes32(type(uint256).max), uint8(27));
        vm.expectRevert(DisputeDesk.BadSignature.selector);
        intake.deliver(id, a, signature);
        signature = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(1)), uint8(0));
        vm.expectRevert(DisputeDesk.BadSignature.selector);
        intake.deliver(id, a, signature);
        _accounting(INITIAL_POOL, 15e17, 5e17);
        _installSigner();
        _verdict(id, true);
    }

    function testFuzz_invalidFailureStatusesDoNotReleaseFunds(uint8 status) public {
        if (status == 1 || status == 2) status = 0;
        bytes32 id = _file(alice, claim);
        vm.expectRevert(DisputeDesk.InvalidFailureStatus.selector);
        intake.fail(id, status);
        _accounting(INITIAL_POOL, 15e17, 5e17);
        assertEq(desk.activeChallenge(claim), id, "invalid status cleared claim");
        intake.fail(id, 2);
    }
}
