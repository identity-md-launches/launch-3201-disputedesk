// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
README — DisputeDesk v1
=======================
trial period - verdicts bind from day one

One immutable court, denominated in the supplied IMD token's base units. No proxy,
upgrade, withdrawal, cancellation, verdict override, owner transfer or rescue.
The owner controls future filings only. Pausing never blocks a callback or funding.

Ethereum mainnet (chain 1), static constructor arguments, IN ORDER:
  imdToken:        0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7
  intake:          0xa43e6f75ee006411f79ac1c84120606c2330de82
  owner:           0xbe80e5979313cf8aff2b8e54e615fe3ecd8358f5
  bond:            1000000000000000000
  bountyMultiplier: 1 (an integer multiplier, NOT basis points)
  oracleFee:       500000000000000000
  rubricHash:      0x494c69552db9fd948e2f4bce26da4d0b3e08d2e5b1cdfbade546af42e677b0b9

Deployment starts paused, rubricURI and recordURI empty. The newsroom calls:
  setRubric(the hash above, "https://openinterest-ai.github.io/paper/rubric.txt")
  setRecordURI("https://openinterest-ai.github.io/paper/")
  approve this court for 4500000000000000000 IMD base units, on the token
  fundPool(4500000000000000000)
  setPaused(false)
Deployment and explorer verification belong to the launch service, not this source.

Every dial (owner only; every change emits an event):
  setBond: positive bond, at least oracleFee; payout arithmetic must fit uint256.
  setBountyMultiplier: nonnegative integer; bounty = bond * bountyMultiplier.
  setOracleFee: nonnegative, at most bond, paid from the filing's bond.
  setRubric: nonzero sha256 and a nonempty UTF-8 URI, at most 500 bytes.
  setRecordURI: nonempty UTF-8 URI, at most 500 bytes.
  setIntake: nonzero address other than this court; code is checked at filing.
  setPaused: blocks new filings only; unpausing requires both configured URIs.
All terms, including both URIs, are snapshotted before any external call.
The token and owner are immutable. Panel 5, quorum 3, 72-hour relative window,
604800-second validity and rejection cooldown, and 3 open filings per address
are constants. URI bounds keep the decoded question below 2000 bytes. JSON text
is UTF-8 validated and escaped. evidenceHash is sha256, or zero for "unpinned".

Money flow for the initial terms, in IMD:
  Filing: pull 1 from challenger; Intake takes 0.5; escrow retains 0.5.
  Reserve 1.5 of the existing pool (bounty 1 + reimbursement of fee 0.5).
  Upheld: release escrow 0.5 plus pool 1.5 to challenger (total 2).
  Rejected: escrow 0.5 to the immutable owner; pool reservation released;
            claim cooldown starts at settlement and lasts seven days.
  Failed/refused: escrow 0.5 to challenger; reservation released; no cooldown.
The oracle fee is spent in every path. fundPool is the only accounting intake
to the pool. Direct token donations remain surplus and cannot be recovered.
At transaction boundaries, token balance >= poolBalance + escrowedBonds, and
reservedBounties <= poolBalance. Reservations include the oracle-fee refund.

Oracle integration and trust:
The callback uses the protocol's complete 15-field attestation, in the court's
EIP-712 domain (IdentityMD Oracle, version 2), and verifies the supplied network
signer 0x5598aa9146215bc13eb26f2c692ad1461fd32982. ERC-1271 is supported if that
address has code. The signer is fixed: there is no owner verdict-signing power.
Only the ORIGINAL intake can answer an existing, Open request. The intake id and
oracle UUID differ; both are protected against reuse. The required relative
window is resolved off chain, so pairing questionHash with the intake request
relies on the intake's writer, as in the supplied protocol. Failure notifications
are unsigned and accepted only for an existing request from its original intake.
The binding brief requires automatic payout/refund inside the 200000-gas callback
and forbids cancellation; there is no timeout or alternate payout path. If the
oracle never delivers, or the token prevents a transfer, that challenge remains
Open. Intake/signer reliability and the IMD token's normal ERC-20 behavior are
external dependencies. A changed intake must use the same attestation protocol.

Rehearsal script (bash; copy this block to a local script after deployment):
Use a staged edition containing the known-false exact claim "2 + 2 = 5." and
public evidence showing the arithmetic. Hash the actual edition and exact claim
bytes with sha256. A rehearsal is a real, binding challenge and spends IMD.
Supply the placeholders below; no private key belongs in this repository.

  #!/usr/bin/env bash
  set -euo pipefail
  : "${RPC_URL:?Ethereum mainnet RPC}"
  : "${DESK:?confirmed DisputeDesk deployment address}"
  : "${CHALLENGER_ACCOUNT:?local cast keystore account name}"
  EDITION_HASH='<0x-prefixed sha256 of the staged edition>'
  CLAIM_HASH='<0x-prefixed sha256 of the exact known-false claim>'
  EVIDENCE_URI='<public evidence URI>'
  EVIDENCE_HASH='<0x-prefixed sha256 of the evidence, or 64 zero hex digits after 0x>'
  [[ "$EDITION_HASH" =~ ^0x[0-9a-fA-F]{64}$ ]]
  [[ "$CLAIM_HASH" =~ ^0x[0-9a-fA-F]{64}$ ]]
  [[ "$EVIDENCE_HASH" =~ ^0x[0-9a-fA-F]{64}$ ]]
  [[ -n "$EVIDENCE_URI" && "$EVIDENCE_URI" != '<'* ]]
  test "$(cast chain-id --rpc-url "$RPC_URL")" = 1
  test "$(cast call --rpc-url "$RPC_URL" "$DESK" 'paused()(bool)')" = false
  IMD_TOKEN=0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7
  BOND=$(cast call --rpc-url "$RPC_URL" "$DESK" 'bond()(uint256)' | awk '{print $1}')
  cast send --rpc-url "$RPC_URL" --account "$CHALLENGER_ACCOUNT" "$IMD_TOKEN" \
    'approve(address,uint256)' "$DESK" "$BOND"
  cast send --rpc-url "$RPC_URL" --account "$CHALLENGER_ACCOUNT" "$DESK" \
    'challenge(bytes32,bytes32,string,bytes32)' \
    "$EDITION_HASH" "$CLAIM_HASH" "$EVIDENCE_URI" "$EVIDENCE_HASH"

Build/check: forge build; FOUNDRY_FUZZ_SEED=0xccfb8134b3161993131ad8f9b29c896abb996959d9bca8e8e335f0e4ad067628 forge test
The assignment permits only this source and foundry.toml as deliverables; this
README and rehearsal are embedded here, and local tests live in test/scratch/.

Review notes:
  - Reentrancy: every token-moving entry point shares one lock. The request id
    can only be stored after Intake returns it; synchronous callbacks and nested
    filings are refused throughout that interval. Settlement effects precede
    the payout. The signature check uses staticcall and cannot change state.
  - Funding/approvals: incoming amounts and the Intake's fee debit are checked
    exactly; approvals are limited to one fee and cleared before filing returns.
  - Time comparisons implement the required cooldown and signed validity window;
    the oracle timestamp tolerance is 300 seconds, matching the pinned protocol.
  - UTF-8 and JSON loops have fixed input bounds; no loop scans stored challenges.
  - Protocol scope: the brief's relative window, automatic failure refunds and
    no-cancellation rule intentionally differ from the generic consumer example.
    The liveness and request-pairing assumptions are documented above.
*/

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external returns (bytes32 requestId);
}

/// @dev Struct and hash encoding from the pinned IdentityMD OracleAttestation.sol.
///      All functions are internal; there are no linked runtime dependencies.
library OracleAttestation {
    struct Attestation {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    bytes32 internal constant TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );

    function hashStruct(Attestation calldata a) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                abi.encode(
                    TYPEHASH,
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock
                ),
                abi.encode(
                    a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                )
            )
        );
    }
}

/// @title DisputeDesk — the autonomous dispute court of Open Interest
/// @notice trial period - verdicts bind from day one
contract DisputeDesk {
    enum Status {
        Open,
        Upheld,
        Rejected,
        Failed
    }

    struct Challenge {
        address challenger;
        uint256 bond;
        uint256 bounty;
        uint256 oracleFee;
        bytes32 editionHash;
        bytes32 claimHash;
        string evidenceURI;
        bytes32 evidenceHash;
        bytes32 rubricHash;
        address intake;
        Status status;
        bytes32 requestId;
        uint256 filedAt;
        uint256 bountyMultiplier;
        string rubricURI;
        string recordURI;
    }

    string public constant metadata = "DisputeDesk v1: trial period - verdicts bind from day one";
    uint256 public constant COOLDOWN_SECONDS = 604800;
    uint256 public constant MAX_OPEN_CHALLENGES = 3;
    uint256 public constant MAX_URI_BYTES = 500;
    uint16 public constant PANEL_SIZE = 5;
    uint16 public constant QUORUM = 3;
    uint256 public constant ISSUED_AT_TOLERANCE = 5 minutes;
    bytes32 public constant ACTION = bytes32("oracle.request@oracle-1");
    address public constant oracleSigner = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;

    address public immutable imdToken;
    address public immutable owner;
    address public intake;
    uint256 public bond;
    uint256 public bountyMultiplier;
    uint256 public oracleFee;
    bytes32 public rubricHash;
    string public rubricURI;
    string public recordURI;
    bool public paused = true;

    uint256 public poolBalance;
    /// @notice Sum of bounty + oracleFee for all Open challenges; part of poolBalance.
    uint256 public reservedBounties;
    /// @notice Sum of bond - oracleFee for all Open challenges; never part of the pool.
    uint256 public escrowedBonds;
    mapping(bytes32 => bytes32) public activeChallenge;
    mapping(bytes32 => uint256) public cooldownUntil;
    mapping(address => uint256) public openChallenges;
    mapping(bytes32 => bool) public consumed;
    mapping(bytes32 => Challenge) private _challenges;
    uint256 private _entered = 1;

    bytes16 private constant HEX = "0123456789abcdef";
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    error NotOwner();
    error Reentrancy();
    error InvalidAddress();
    error InvalidTerms();
    error InvalidURI();
    error Paused();
    error NotConfigured();
    error WrongChain();
    error ClaimAlreadyOpen();
    error ClaimInCooldown();
    error TooManyOpenChallenges();
    error InsufficientPool();
    error InvalidRequestId();
    error NotOpen();
    error NotTheIntake();
    error TokenCallFailed();
    error IncorrectTokenAmount();
    error InvalidAttestation();
    error BadSignature();
    error AlreadyConsumed();
    error InvalidFailureStatus();

    event PoolFunded(address indexed funder, uint256 amount);
    event ChallengeFiled(
        bytes32 indexed requestId,
        address indexed challenger,
        bytes32 indexed claimHash,
        bytes32 editionHash,
        string evidenceURI,
        bytes32 evidenceHash
    );
    event ChallengeSettled(bytes32 indexed requestId, Status status, address indexed recipient, uint256 amount);
    event Correction(bytes32 indexed editionHash, bytes32 indexed claimHash, bytes32 indexed requestId);
    event OracleFailure(bytes32 indexed requestId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered);
    event BondSet(uint256 bond);
    event BountyMultiplierSet(uint256 bountyMultiplier);
    event OracleFeeSet(uint256 oracleFee);
    event RubricSet(bytes32 indexed rubricHash, string rubricURI);
    event RecordURISet(string recordURI);
    event IntakeSet(address indexed intake);
    event PausedSet(bool paused);

    constructor(
        address imdToken_,
        address intake_,
        address owner_,
        uint256 bond_,
        uint256 bountyMultiplier_,
        uint256 oracleFee_,
        bytes32 rubricHash_
    ) {
        if (
            imdToken_ == address(0) || intake_ == address(0) || owner_ == address(0) || intake_ == address(this)
                || imdToken_ == address(this)
        ) revert InvalidAddress();
        _validateTerms(bond_, bountyMultiplier_, oracleFee_);
        if (rubricHash_ == bytes32(0)) revert InvalidTerms();
        // No external calls: dependency code need not exist during factory rehearsal.
        imdToken = imdToken_;
        intake = intake_;
        owner = owner_;
        bond = bond_;
        bountyMultiplier = bountyMultiplier_;
        oracleFee = oracleFee_;
        rubricHash = rubricHash_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_entered != 1) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    function challenges(bytes32 requestId) external view returns (Challenge memory) {
        return _challenges[requestId];
    }

    /// @notice Anyone can permanently contribute IMD to the bounty pool, including while paused.
    function fundPool(uint256 amount) external nonReentrant {
        poolBalance += amount;
        _pullExact(msg.sender, amount);
        emit PoolFunded(msg.sender, amount);
    }

    function challenge(bytes32 editionHash, bytes32 claimHash, string calldata evidenceURI, bytes32 evidenceHash)
        external
        nonReentrant
        returns (bytes32 requestId)
    {
        if (paused) revert Paused();
        if (block.chainid != 1) revert WrongChain();
        if (activeChallenge[claimHash] != bytes32(0)) revert ClaimAlreadyOpen();
        if (block.timestamp < cooldownUntil[claimHash]) revert ClaimInCooldown();
        if (openChallenges[msg.sender] >= MAX_OPEN_CHALLENGES) revert TooManyOpenChallenges();
        _validateURI(bytes(evidenceURI));

        Challenge memory c;
        c.challenger = msg.sender;
        c.bond = bond;
        c.bountyMultiplier = bountyMultiplier;
        c.bounty = c.bond * c.bountyMultiplier;
        c.oracleFee = oracleFee;
        c.editionHash = editionHash;
        c.claimHash = claimHash;
        c.evidenceURI = evidenceURI;
        c.evidenceHash = evidenceHash;
        c.rubricHash = rubricHash;
        c.intake = intake;
        c.filedAt = block.timestamp;
        c.rubricURI = rubricURI;
        c.recordURI = recordURI;
        uint256 reservation = c.bounty + c.oracleFee;
        if (poolBalance - reservedBounties < reservation) revert InsufficientPool();
        if (c.intake.code.length == 0) revert InvalidAddress();
        bytes memory body = _requestBody(c);

        // Accounting effects precede token/Intake calls. The shared guard also prevents
        // synchronous callbacks before the Intake has returned its authoritative id.
        reservedBounties += reservation;
        escrowedBonds += c.bond - c.oracleFee;
        ++openChallenges[msg.sender];
        _pullExact(msg.sender, c.bond);
        _forceApprove(c.intake, c.oracleFee);
        uint256 beforeFee = IERC20(imdToken).balanceOf(address(this));
        requestId = IIntake(c.intake)
            .requestWithFailure(
                ACTION,
                body,
                IIntake.Callback(address(this), this.settle.selector),
                this.failure.selector,
                imdToken,
                c.oracleFee
            );
        _forceApprove(c.intake, 0);
        uint256 afterFee = IERC20(imdToken).balanceOf(address(this));
        if (afterFee > beforeFee || beforeFee - afterFee != c.oracleFee) revert IncorrectTokenAmount();
        // Never reuse even a settled id, including after an intake migration.
        if (requestId == bytes32(0) || _challenges[requestId].challenger != address(0)) revert InvalidRequestId();
        c.requestId = requestId;
        _challenges[requestId] = c;
        activeChallenge[claimHash] = requestId;
        emit ChallengeFiled(requestId, msg.sender, claimHash, editionHash, evidenceURI, evidenceHash);
    }

    /// @notice Canonical oracle callback. Its first id is the Intake id, not a.requestId.
    function settle(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        nonReentrant
    {
        Challenge storage c = _openRequest(requestId);
        if (
            a.chainId != 1 || a.answerType != 0 || a.answer.length != 32 || a.requestId == bytes32(0)
                || a.panelSize != PANEL_SIZE || a.quorum != QUORUM || a.agreed < QUORUM || a.agreed > PANEL_SIZE
                || a.fromBlock > a.toBlock || a.expiresAt < a.issuedAt || block.timestamp > a.expiresAt
                || a.issuedAt > block.timestamp + ISSUED_AT_TOLERANCE
                || uint256(a.issuedAt) + ISSUED_AT_TOLERANCE < c.filedAt
        ) revert InvalidAttestation();
        if (consumed[a.requestId]) revert AlreadyConsumed();
        _verifySignature(attestationDigest(a), signature);
        bool upheld = abi.decode(a.answer, (bool));
        consumed[a.requestId] = true;
        _finish(c, upheld ? Status.Upheld : Status.Rejected);
    }

    /// @notice Canonical failure callback, for status 1 (refused) or 2 (no agreement).
    function failure(bytes32 requestId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered, bytes calldata)
        external
        nonReentrant
    {
        Challenge storage c = _openRequest(requestId);
        if (status != 1 && status != 2) revert InvalidFailureStatus();
        emit OracleFailure(requestId, status, reason, agreed, answered);
        _finish(c, Status.Failed);
    }

    function attestationDigest(OracleAttestation.Attestation calldata a) public view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("IdentityMD Oracle"), keccak256("2"), block.chainid, address(this))
        );
        return keccak256(abi.encodePacked(hex"1901", domain, OracleAttestation.hashStruct(a)));
    }

    function setBond(uint256 value) external onlyOwner {
        _validateTerms(value, bountyMultiplier, oracleFee);
        bond = value;
        emit BondSet(value);
    }

    function setBountyMultiplier(uint256 value) external onlyOwner {
        _validateTerms(bond, value, oracleFee);
        bountyMultiplier = value;
        emit BountyMultiplierSet(value);
    }

    function setOracleFee(uint256 value) external onlyOwner {
        _validateTerms(bond, bountyMultiplier, value);
        oracleFee = value;
        emit OracleFeeSet(value);
    }

    function setRubric(bytes32 hash, string calldata uri) external onlyOwner {
        if (hash == bytes32(0)) revert InvalidTerms();
        _validateURI(bytes(uri));
        rubricHash = hash;
        rubricURI = uri;
        emit RubricSet(hash, uri);
    }

    function setRecordURI(string calldata uri) external onlyOwner {
        _validateURI(bytes(uri));
        recordURI = uri;
        emit RecordURISet(uri);
    }

    function setIntake(address value) external onlyOwner {
        if (value == address(0) || value == address(this)) revert InvalidAddress();
        intake = value;
        emit IntakeSet(value);
    }

    function setPaused(bool value) external onlyOwner {
        if (!value && (bytes(rubricURI).length == 0 || bytes(recordURI).length == 0)) revert NotConfigured();
        paused = value;
        emit PausedSet(value);
    }

    function _openRequest(bytes32 requestId) private view returns (Challenge storage c) {
        c = _challenges[requestId];
        if (c.challenger == address(0) || c.requestId != requestId) revert InvalidRequestId();
        if (msg.sender != c.intake) revert NotTheIntake();
        if (c.status != Status.Open) revert NotOpen();
    }

    function _finish(Challenge storage c, Status status) private {
        uint256 remainder = c.bond - c.oracleFee;
        uint256 reservation = c.bounty + c.oracleFee;
        address recipient = c.challenger;
        uint256 payment = remainder;
        c.status = status;
        delete activeChallenge[c.claimHash];
        --openChallenges[c.challenger];
        reservedBounties -= reservation;
        escrowedBonds -= remainder;
        if (status == Status.Upheld) {
            poolBalance -= reservation;
            payment += reservation;
            emit Correction(c.editionHash, c.claimHash, c.requestId);
        } else if (status == Status.Rejected) {
            recipient = owner;
            cooldownUntil[c.claimHash] = block.timestamp + COOLDOWN_SECONDS;
        }
        emit ChallengeSettled(c.requestId, status, recipient, payment);
        if (payment != 0) _safeTokenCall(abi.encodeCall(IERC20.transfer, (recipient, payment)));
    }

    function _validateTerms(uint256 bond_, uint256 multiplier_, uint256 fee_) private pure {
        // These bounds ensure remainder, reservation and total payout all fit uint256.
        if (bond_ == 0 || fee_ > bond_ || multiplier_ > (type(uint256).max - bond_) / bond_) revert InvalidTerms();
    }

    function _pullExact(address from, uint256 amount) private {
        uint256 beforeBalance = IERC20(imdToken).balanceOf(address(this));
        _safeTokenCall(abi.encodeCall(IERC20.transferFrom, (from, address(this), amount)));
        uint256 afterBalance = IERC20(imdToken).balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert IncorrectTokenAmount();
    }

    function _forceApprove(address spender, uint256 amount) private {
        if (!_tryTokenCall(abi.encodeCall(IERC20.approve, (spender, amount)))) {
            _safeTokenCall(abi.encodeCall(IERC20.approve, (spender, 0)));
            _safeTokenCall(abi.encodeCall(IERC20.approve, (spender, amount)));
        }
    }

    function _safeTokenCall(bytes memory data) private {
        if (!_tryTokenCall(data)) revert TokenCallFailed();
    }

    function _tryTokenCall(bytes memory data) private returns (bool) {
        if (imdToken.code.length == 0) return false;
        (bool ok, bytes memory result) = imdToken.call(data);
        if (!ok) return false;
        if (result.length == 0) return true;
        if (result.length < 32) return false;
        uint256 returned;
        assembly ("memory-safe") { returned := mload(add(result, 32)) }
        return returned == 1;
    }

    function _verifySignature(bytes32 digest, bytes calldata signature) private view {
        if (oracleSigner.code.length != 0) {
            (bool ok, bytes memory result) =
                oracleSigner.staticcall(abi.encodeWithSelector(bytes4(0x1626ba7e), digest, signature));
            if (!ok || result.length < 32 || abi.decode(result, (bytes32)) != bytes32(bytes4(0x1626ba7e))) {
                revert BadSignature();
            }
            return;
        }
        if (signature.length != 65) revert BadSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        // EIP-2 low-s; canonical Ethereum 27/28 recovery ids.
        if (
            uint256(s) > 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0 || (v != 27 && v != 28)
                || ecrecover(digest, v, r, s) != oracleSigner
        ) revert BadSignature();
    }

    function _requestBody(Challenge memory c) private view returns (bytes memory) {
        string memory question = string.concat(
            "Is the identified claim in the Open Interest edition with sha256 ",
            _hex(abi.encodePacked(c.editionHash)),
            " materially wrong, per the cited evidence? Judge by the rubric at ",
            c.rubricURI,
            " (sha256 ",
            _hex(abi.encodePacked(c.rubricHash)),
            "). The claim is the passage with sha256 ",
            _hex(abi.encodePacked(c.claimHash)),
            ". Challenger evidence: ",
            c.evidenceURI,
            ". The edition's verbatim record is published under ",
            c.recordURI,
            ". Answer true for UPHELD, false for REJECTED."
        );
        return bytes.concat(
            '{"v":1,"question":',
            _jsonString(bytes(question)),
            ',"chainId":1,"window":{"hours":72},"answerType":"bool","evidence":"panel",',
            '"panelSize":5,"quorum":3,"validForSeconds":604800,"definitions":{',
            '"burden":"The bond carries the burden of proof. A genuinely conflicting, unverifiable or silent record means REJECTED: a tie goes to the text.",',
            '"evidencehash":"',
            bytes(c.evidenceHash == bytes32(0) ? "unpinned" : _hex(abi.encodePacked(c.evidenceHash))),
            '. If a nonzero hash is given and the sha256 of the material fetched at the evidence URI does not match it, treat the challenger evidence as absent.",',
            '"malformed":"A claim whose exact text cannot be located in the edition means REJECTED."},',
            '"consumer":{"chainId":1,"verifyingContract":"',
            bytes(_hex(abi.encodePacked(address(this)))),
            '"}}'
        );
    }

    /// @dev All callers supply a fixed 20- or 32-byte value.
    function _hex(bytes memory raw) private pure returns (string memory) {
        bytes memory out = new bytes(raw.length * 2 + 2);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i; i < raw.length; ++i) {
            out[2 + 2 * i] = HEX[uint8(raw[i]) >> 4];
            out[3 + 2 * i] = HEX[uint8(raw[i]) & 15];
        }
        return string(out);
    }

    /// @dev Bounded UTF-8 validation: reject overlong encodings, surrogates, incomplete
    ///      sequences and code points above U+10FFFF. ASCII controls are JSON-escaped.
    function _validateURI(bytes memory raw) private pure {
        if (raw.length == 0 || raw.length > MAX_URI_BYTES) revert InvalidURI();
        for (uint256 i; i < raw.length;) {
            uint8 c = uint8(raw[i]);
            if (c < 0x80) {
                ++i;
                continue;
            }
            uint256 n;
            if (c >= 0xc2 && c <= 0xdf) n = 2;
            else if (c >= 0xe0 && c <= 0xef) n = 3;
            else if (c >= 0xf0 && c <= 0xf4) n = 4;
            else revert InvalidURI();
            if (i + n > raw.length) revert InvalidURI();
            uint8 second = uint8(raw[i + 1]);
            if (
                (c == 0xe0 && second < 0xa0) || (c == 0xed && second >= 0xa0) || (c == 0xf0 && second < 0x90)
                    || (c == 0xf4 && second >= 0x90)
            ) revert InvalidURI();
            for (uint256 j = 1; j < n; ++j) {
                uint8 next = uint8(raw[i + j]);
                if (next < 0x80 || next > 0xbf) revert InvalidURI();
            }
            i += n;
        }
    }

    /// @dev The validated question has at most 497 + 3 * MAX_URI_BYTES = 1997 bytes.
    ///      Escaping cannot inject JSON members; UTF-8 multibyte sequences are preserved.
    function _jsonString(bytes memory raw) private pure returns (bytes memory out) {
        out = new bytes(2 + raw.length * 6);
        uint256 j;
        out[j++] = '"';
        for (uint256 i; i < raw.length; ++i) {
            uint8 c = uint8(raw[i]);
            if (c == 0x22 || c == 0x5c) {
                out[j++] = "\\";
                out[j++] = bytes1(c);
            } else if (c < 0x20) {
                out[j++] = "\\";
                out[j++] = "u";
                out[j++] = "0";
                out[j++] = "0";
                out[j++] = HEX[c >> 4];
                out[j++] = HEX[c & 15];
            } else {
                out[j++] = bytes1(c);
            }
        }
        out[j++] = '"';
        assembly ("memory-safe") { mstore(out, j) }
    }
}
