// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IVerifiers.sol";
import "./MerkleTreeWithHistory.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract zkTips is MerkleTreeWithHistory {
    struct Key {
        uint256 g;
        uint256 n;
        uint256 powN2;
    }

    struct User {
        uint encryptedBalance;
        Key key;
        bytes32 authCommitment;
        mapping(uint256 => Allowance) allowance; // ID -> balances
    }

    struct Allowance {
        uint encryptedHolderBalance;
        uint encryptedSpenderBalance;
    }

    event Commit(
        bytes32 indexed commitment,
        uint32 leafIndex,
        uint256 timestamp
    );

    // ID - User
    mapping(uint256 => User) private users;

    mapping(bytes32 => bool) public nullifiers;
    mapping(bytes32 => bool) public commitments;

    uint ids;

    IERC20 public token;

    ICreateDepositCommitmentVerifier private createDepositVerifier;
    INullifyDepositCommitmentVerifier private nullifyDepositVerifier;
    ITransferVerifier private transferVerifier;
    IApproveVerifier private approveVerifier;
    ITransferFromVerifier private transferFromVerifier;
    ICreateWithdrawCommitmentVerifier private createWithdrawVerifier;
    INullifyWithdrawCommitmentVerifier private nullifWithdrawCommitmentVerifier;

    constructor(
        uint32 _levels,
        address _hasher,
        address _token,
        address _createDepositVerifierAddr,
        address _nullifyDepositVerifier,
        address _transferVerifier,
        address _approveVerifier,
        address _transferFromVerifier,
        address _createWithdrawVerifier,
        address _nullifWithdrawCommitmentVerifier
    ) MerkleTreeWithHistory(_levels, IHasher(_hasher)) {
        token = IERC20(_token);

        createDepositVerifier = ICreateDepositCommitmentVerifier(
            _createDepositVerifierAddr
        );
        nullifyDepositVerifier = INullifyDepositCommitmentVerifier(
            _nullifyDepositVerifier
        );
        transferVerifier = ITransferVerifier(_transferVerifier);
        approveVerifier = IApproveVerifier(_approveVerifier);
        transferFromVerifier = ITransferFromVerifier(_transferFromVerifier);
        createWithdrawVerifier = ICreateWithdrawCommitmentVerifier(
            _createWithdrawVerifier
        );
        nullifWithdrawCommitmentVerifier = INullifyWithdrawCommitmentVerifier(
            _nullifWithdrawCommitmentVerifier
        );
    }

    function createDepositCommitment(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[2] calldata input
    ) external {
        require(
            createDepositVerifier.verifyProof(a, b, c, input),
            "Invalid proof"
        );

        token.transferFrom(msg.sender, address(this), input[0] * 1e18);
        _commit(bytes32(input[1]));
    }

    function createWithdrawalCommitment(
        uint256 idFrom,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[3] calldata input
    ) external {
        require(
            createWithdrawVerifier.verifyProof(a, b, c, input),
            "Invalid proof"
        );

        User storage sender = users[idFrom];

        require(bytes32(input[2]) == sender.authCommitment, "Unauthorized");

        sender.encryptedBalance = _update(
            sender.encryptedBalance,
            input[1],
            sender.key.powN2
        );

        _commit(bytes32(input[0]));
    }

    function nullifyDepositCommitment(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[6] calldata input,
        uint256 authCommitment,
        uint256 id
    ) external {
        require(
            nullifyDepositVerifier.verifyProof(a, b, c, input),
            "Invalid proof"
        );
        require(
            !nullifiers[bytes32(input[0])],
            "The nullifier has been submitted"
        );
        require(isKnownRoot(bytes32(input[1])), "Cannot find your merkle root");

        id = id == 0 ? ids : id;

        nullifiers[bytes32(input[0])] = true;

        User storage user = users[id];
        if (user.key.n == 0) {
            // Structure is empty, initialize it
            user.authCommitment = bytes32(authCommitment);
            user.encryptedBalance = input[2];
            user.key.g = input[3];
            user.key.n = input[5];
            user.key.powN2 = input[5] * input[5];

            ids++;
        } else {
            // Structure exists, verify keys match and update balance
            require(
                user.key.n == input[5] && user.key.g == input[3],
                "Keys mismatch"
            );
            user.authCommitment = bytes32(authCommitment);
            user.encryptedBalance = _update(
                user.encryptedBalance,
                input[2],
                user.key.powN2
            );
        }
    }

    function nullifyWithdrawalCommitment(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[3] calldata input
    ) external {
        require(
            nullifWithdrawCommitmentVerifier.verifyProof(a, b, c, input),
            "Invalid proof"
        );

        require(
            !nullifiers[bytes32(input[0])],
            "The nullifier has been submitted"
        );
        require(isKnownRoot(bytes32(input[1])), "Cannot find your merkle root");

        nullifiers[bytes32(input[0])] = true;

        token.transfer(msg.sender, input[2] * 1e18);
    }

    function transfer(
        uint256 idFrom,
        uint256 idTo,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[4] calldata input
    ) external {
        require(transferVerifier.verifyProof(a, b, c, input), "Invalid proof");

        User storage receiver = users[idTo];
        User storage sender = users[idFrom];

        require(bytes32(input[3]) == sender.authCommitment, "Unauthorized");

        unchecked {
            receiver.encryptedBalance = _update(
                receiver.encryptedBalance,
                input[2],
                receiver.key.powN2
            );

            sender.encryptedBalance = _update(
                sender.encryptedBalance,
                input[1],
                sender.key.powN2
            );
        }
    }

    function approve(
        uint256 holderID,
        uint256 spenderID,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[5] calldata input
    ) external {
        require(approveVerifier.verifyProof(a, b, c, input), "Invalid proof");

        User storage holder = users[holderID];

        require(bytes32(input[3]) == holder.authCommitment, "Unauthorized");

        unchecked {
            // уменьшаем баланс
            holder.encryptedBalance =
                (holder.encryptedBalance * input[0]) %
                holder.key.powN2;
        }

        Allowance storage allowance = holder.allowance[spenderID];

        if (
            allowance.encryptedHolderBalance == 0 &&
            allowance.encryptedSpenderBalance == 0
        ) {
            allowance.encryptedHolderBalance = input[1];
            allowance.encryptedSpenderBalance = input[2];
        } else {
            User storage spender = users[spenderID];

            unchecked {
                allowance.encryptedHolderBalance = _update(
                    allowance.encryptedHolderBalance,
                    input[1],
                    holder.key.powN2
                );

                allowance.encryptedSpenderBalance = _update(
                    allowance.encryptedSpenderBalance,
                    input[2],
                    spender.key.powN2
                );
            }
        }
    }

    function transferFrom(
        uint256 idFrom,
        uint256 idSpender,
        uint256 idTo,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[5] calldata input
    ) external {
        require(
            transferFromVerifier.verifyProof(a, b, c, input),
            "Invalid proof"
        );

        User storage spender = users[idSpender];

        require(bytes32(input[3]) == spender.authCommitment, "Unauthorized");

        User storage holder = users[idFrom];
        User storage receiver = users[idTo];

        Allowance storage allowance = users[idFrom].allowance[idSpender];

        unchecked {
            receiver.encryptedBalance = _update(
                receiver.encryptedBalance,
                input[2],
                receiver.key.powN2
            );

            allowance.encryptedSpenderBalance = _update(
                allowance.encryptedSpenderBalance,
                input[1],
                spender.key.powN2
            );

            allowance.encryptedHolderBalance = _update(
                allowance.encryptedHolderBalance,
                input[0],
                holder.key.powN2
            );
        }
    }

    function balanceOf(uint256 _id) external view returns (uint256) {
        return users[_id].encryptedBalance;
    }

    function getPubKey(uint256 _id) external view returns (Key memory) {
        return users[_id].key;
    }

    function getAllowance(
        uint256 holderID,
        uint256 spenderID
    ) external view returns (Allowance memory) {
        return users[holderID].allowance[spenderID];
    }

    function _commit(bytes32 _commitment) internal {
        require(!commitments[_commitment], "The commitment has been submitted");
        commitments[_commitment] = true;
        uint32 insertedIndex = _insert(_commitment);
        emit Commit(_commitment, insertedIndex, block.timestamp);
    }

    function _update(
        uint256 encryptedBalance,
        uint256 value,
        uint256 powN2
    ) internal pure returns (uint256) {
        return (encryptedBalance * value) % powN2;
    }
}
