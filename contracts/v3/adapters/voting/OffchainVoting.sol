pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

// SPDX-License-Identifier: MIT

import "../../core/DaoRegistry.sol";
import "../../core/DaoConstants.sol";
import "../interfaces/IVoting.sol";
import "../../guards/MemberGuard.sol";
import "../../guards/AdapterGuard.sol";
import "../../helpers/FlagHelper.sol";

contract OffchainVotingContract is
    IVoting,
    DaoConstants,
    MemberGuard,
    AdapterGuard
{
    using FlagHelper for uint256;

    struct VotingConfig {
        uint256 votingPeriod;
        uint256 gracePeriod;
        uint256 stakingAmount;
    }
    struct Voting {
        uint256 blockNumber;
        address reporter;
        bytes32 resultRoot;
        uint256 nbVoters;
        uint256 nbYes;
        uint256 nbNo;
        uint256 startingTime;
        uint256 gracePeriodStartingTime;
        bool isChallenged;
        mapping(address => bool) fallbackVotes;
        uint256 fallbackVotesCount;
    }

    struct VoteResultNode {
        address voter;
        uint256 nbNo;
        uint256 nbYes;
        uint256 weight;
        bytes sig;
        uint256 index;
        bytes32[] proof;
    }

    mapping(address => mapping(uint256 => Voting)) public votes;
    mapping(address => VotingConfig) public votingConfigs;

    function registerDao(
        DaoRegistry dao,
        uint256 votingPeriod,
        uint256 gracePeriod
    ) external override onlyAdapter(dao) {
        votingConfigs[address(dao)].votingPeriod = votingPeriod;
        votingConfigs[address(dao)].gracePeriod = gracePeriod;
    }

    function submitVoteResult(
        DaoRegistry dao,
        uint256 proposalId,
        uint256 nbYes,
        uint256 nbNo,
        bytes32 resultRoot
    ) external {
        Voting storage vote = votes[address(dao)][proposalId];
        require(vote.blockNumber > 0, "the vote has not started yet");
        /**
        What needs to be checked before submitting a vote result
        - if the grace period has ended, do nothing
        - if it's the first result, is this a right time to submit it?
             * is the diff between nbYes and nbNo +50% of the votes ?
             * is this after the voting period ?
        - if we already have a result that has been challenged
            * same as if there were no result yet

        - if we already have a result that has not been challenged
            * is the new one heavier than the previous one ?
         */
        if (vote.resultRoot == bytes32(0) || vote.isChallenged) {
            require(
                _readyToSubmitResult(dao, vote, nbYes, nbNo),
                "the voting period need to end or the difference between yes and no need to be more than 50% of the votes"
            );
            _submitVoteResult(dao, vote, nbYes, nbNo, resultRoot);
        } else {
            require(
                nbYes + nbNo > vote.nbYes + vote.nbNo,
                "to override a result, the sum of yes and no has to be greater than the current one"
            );
            _submitVoteResult(dao, vote, nbYes, nbNo, resultRoot);
        }
    }

    //TODO: generale challenge to go through each node to see which vote has been missing

    function _readyToSubmitResult(
        DaoRegistry dao,
        Voting storage vote,
        uint256 nbYes,
        uint256 nbNo
    ) internal view returns (bool) {
        uint256 diff;
        if (vote.nbYes > nbNo) {
            diff = nbYes - nbNo;
        } else {
            diff = nbNo - nbYes;
        }
        if (diff * 2 > dao.totalShares()) {
            return true;
        }

        uint256 votingPeriod = votingConfigs[address(dao)].votingPeriod;

        return vote.startingTime + votingPeriod > block.timestamp;
    }

    function _submitVoteResult(
        DaoRegistry dao,
        Voting storage vote,
        uint256 nbYes,
        uint256 nbNo,
        bytes32 resultRoot
    ) internal {
        _lockFunds(dao, msg.sender);
        vote.nbNo = nbNo;
        vote.nbYes = nbYes;
        vote.resultRoot = resultRoot;
        vote.reporter = msg.sender;
        vote.isChallenged = false;
        vote.gracePeriodStartingTime = block.timestamp;
    }

    function _lockFunds(DaoRegistry dao, address member) internal {
        dao.lockLoot(member, votingConfigs[address(dao)].stakingAmount);
    }

    function _releaseFunds(DaoRegistry dao, address member) internal {
        dao.releaseLoot(member, votingConfigs[address(dao)].stakingAmount);
    }

    function startNewVotingForProposal(
        DaoRegistry dao,
        uint256 proposalId,
        bytes memory data /*onlyAdapter(dao)*/
    ) external override returns (uint256) {
        require(
            msg.sender == address(dao),
            "only the DaoRegistry can call this method"
        );
        // it is called from Registry
        require(
            data.length == 32,
            "vote data should represent the block number for snapshot"
        );

        uint256 blockNumber;

        assembly {
            blockNumber := mload(add(data, 32))
        }

        require(
            blockNumber < block.number,
            "snapshot block number should not be in the future"
        );
        require(blockNumber > 0, "block number cannot be 0");

        votes[address(dao)][proposalId].startingTime = block.timestamp;
        votes[address(dao)][proposalId].blockNumber = blockNumber;
    }

    /**
    possible results here:
    0: has not started
    1: tie
    2: pass
    3: not pass
    4: in progress
     */
    function voteResult(DaoRegistry dao, uint256 proposalId)
        external
        override
        view
        returns (uint256 state)
    {
        Voting storage vote = votes[address(dao)][proposalId];
        if (vote.startingTime == 0) {
            return 0;
        }

        if (vote.isChallenged) {
            return 4;
        }

        if (
            block.timestamp <
            vote.startingTime + votingConfigs[address(dao)].votingPeriod
        ) {
            return 4;
        }

        if (
            block.timestamp <
            vote.gracePeriodStartingTime +
                votingConfigs[address(dao)].gracePeriod
        ) {
            return 4;
        }

        if (vote.nbYes > vote.nbNo) {
            return 2;
        }
        if (vote.nbYes < vote.nbNo) {
            return 3;
        }

        return 1;
    }

    function challengeWrongSignature(
        DaoRegistry dao,
        uint256 proposalId,
        VoteResultNode memory nodeCurrent
    ) external {
        Voting storage vote = votes[address(dao)][proposalId];
        bytes32 resultRoot = vote.resultRoot;
        uint256 blockNumber = vote.blockNumber;
        require(resultRoot != bytes32(0), "no result available yet!");
        bytes32 hashCurrent = _nodeHash(nodeCurrent);
        require(
            verify(resultRoot, hashCurrent, nodeCurrent.proof),
            "proof check for current invalid for current node"
        );

        bytes32 proposalHash = keccak256(
            abi.encode(blockNumber, address(dao), proposalId)
        );
        //return 1 if yes, 2 if no and 0 if the vote is incorrect
        if (_hasVoted(nodeCurrent.voter, proposalHash, nodeCurrent.sig) == 0) {
            _challengeResult(dao, proposalId);
        }
    }

    function challengeWrongWeight(
        DaoRegistry dao,
        uint256 proposalId,
        VoteResultNode memory nodeCurrent
    ) external {
        Voting storage vote = votes[address(dao)][proposalId];
        bytes32 resultRoot = vote.resultRoot;
        uint256 blockNumber = vote.blockNumber;
        require(resultRoot != bytes32(0), "no result available yet!");
        bytes32 hashCurrent = _nodeHash(nodeCurrent);
        require(
            verify(resultRoot, hashCurrent, nodeCurrent.proof),
            "proof check for current invalid for current node"
        );

        uint256 correctWeight = dao.getPriorVotes(
            nodeCurrent.voter,
            blockNumber
        );

        //Incorrect weight
        if (correctWeight != nodeCurrent.weight) {
            _challengeResult(dao, proposalId);
        }
    }

    function challengeDuplicate(
        DaoRegistry dao,
        uint256 proposalId,
        VoteResultNode memory node1,
        VoteResultNode memory node2
    ) external {
        Voting storage vote = votes[address(dao)][proposalId];
        bytes32 resultRoot = vote.resultRoot;
        require(resultRoot != bytes32(0), "no result available yet!");
        bytes32 hashCurrent = _nodeHash(node1);
        bytes32 hashPrevious = _nodeHash(node2);
        require(
            verify(resultRoot, hashCurrent, node1.proof),
            "proof check for current invalid for current node"
        );
        require(
            verify(resultRoot, hashPrevious, node2.proof),
            "proof check for previous invalid for previous node"
        );

        if (node1.voter == node2.voter) {
            _challengeResult(dao, proposalId);
        }
    }

    function challengeWrongStep(
        DaoRegistry dao,
        uint256 proposalId,
        VoteResultNode memory nodePrevious,
        VoteResultNode memory nodeCurrent
    ) external {
        Voting storage vote = votes[address(dao)][proposalId];
        bytes32 resultRoot = vote.resultRoot;
        uint256 blockNumber = vote.blockNumber;
        require(resultRoot != bytes32(0), "no result available yet!");
        bytes32 hashCurrent = _nodeHash(nodeCurrent);
        bytes32 hashPrevious = _nodeHash(nodePrevious);
        require(
            verify(resultRoot, hashCurrent, nodeCurrent.proof),
            "proof check for current invalid for current node"
        );
        require(
            verify(resultRoot, hashPrevious, nodePrevious.proof),
            "proof check for previous invalid for previous node"
        );

        bytes32 proposalHash = keccak256(
            abi.encode(blockNumber, address(dao), proposalId)
        );

        require(
            nodeCurrent.index == nodePrevious.index + 1,
            "those nodes are not consecutive"
        );

        //voters not in order
        if (nodeCurrent.voter > nodePrevious.voter) {
            _challengeResult(dao, proposalId);
        }

        _checkStep(dao, nodeCurrent, nodePrevious, proposalHash, proposalId);
    }

    function _nodeHash(VoteResultNode memory node)
        internal
        pure
        returns (bytes32)
    {
        return
            keccak256(
                abi.encode(
                    node.voter,
                    node.weight,
                    node.sig,
                    node.nbYes,
                    node.nbNo,
                    node.index
                )
            );
    }

    function _checkStep(
        DaoRegistry dao,
        VoteResultNode memory nodeCurrent,
        VoteResultNode memory nodePrevious,
        bytes32 proposalHash,
        uint256 proposalId
    ) internal {
        if (_hasVotedYes(nodeCurrent.voter, proposalHash, nodeCurrent.sig)) {
            if (nodePrevious.nbYes + 1 != nodeCurrent.nbYes) {
                _challengeResult(dao, proposalId);
            } else if (nodePrevious.nbNo != nodeCurrent.nbNo) {
                _challengeResult(dao, proposalId);
            }
        } else {
            if (nodePrevious.nbYes != nodeCurrent.nbYes) {
                _challengeResult(dao, proposalId);
            } else if (nodePrevious.nbNo + 1 != nodeCurrent.nbNo) {
                _challengeResult(dao, proposalId);
            }
        }
    }

    function _challengeResult(DaoRegistry dao, uint256 proposalId) internal {
        dao.burnLockedLoot(
            votes[address(dao)][proposalId].reporter,
            votingConfigs[address(dao)].stakingAmount
        );
        votes[address(dao)][proposalId].isChallenged = true;
    }

    function getSignedHash(
        bytes32 snapshotRoot,
        address dao,
        uint256 proposalId
    ) external pure returns (bytes32) {
        bytes32 proposalHash = keccak256(
            abi.encode(snapshotRoot, dao, proposalId)
        );
        return keccak256(abi.encode(proposalHash, 1));
    }

    function getSignedAddress(
        bytes32 snapshotRoot,
        address dao,
        uint256 proposalId,
        bytes calldata sig
    ) external pure returns (address) {
        bytes32 proposalHash = keccak256(
            abi.encode(snapshotRoot, dao, proposalId)
        );
        return
            recover(
                keccak256(
                    abi.encodePacked(
                        "\x19Ethereum Signed Message:\n32",
                        keccak256(abi.encode(proposalHash, 1))
                    )
                ),
                sig
            );
    }

    function _hasVotedYes(
        address voter,
        bytes32 proposalHash,
        bytes memory sig
    ) internal pure returns (bool) {
        if (
            recover(
                keccak256(
                    abi.encodePacked(
                        "\x19Ethereum Signed Message:\n32",
                        keccak256(abi.encode(proposalHash, 1))
                    )
                ),
                sig
            ) == voter
        ) {
            return true;
        } else if (
            recover(
                keccak256(
                    abi.encodePacked(
                        "\x19Ethereum Signed Message:\n32",
                        keccak256(abi.encode(proposalHash, 2))
                    )
                ),
                sig
            ) == voter
        ) {
            return false;
        } else {
            revert("invalid signature or signed for neither yes nor no");
        }
    }

    function _hasVoted(
        address voter,
        bytes32 proposalHash,
        bytes memory sig
    ) internal pure returns (uint256) {
        if (
            recover(
                keccak256(
                    abi.encodePacked(
                        "\x19Ethereum Signed Message:\n32",
                        keccak256(abi.encode(proposalHash, 1))
                    )
                ),
                sig
            ) == voter
        ) {
            return 1;
        } else if (
            recover(
                keccak256(
                    abi.encodePacked(
                        "\x19Ethereum Signed Message:\n32",
                        keccak256(abi.encode(proposalHash, 2))
                    )
                ),
                sig
            ) == voter
        ) {
            return 2;
        } else {
            return 0;
        }
    }

    /**
     * @dev Recover signer address from a message by using his signature
     * @param hash bytes32 message, the hash is the signed message. What is recovered is the signer address.
     * @param sig bytes signature, the signature is generated using web3.eth.sign()
     */
    function recover(bytes32 hash, bytes memory sig)
        public
        pure
        returns (address)
    {
        bytes32 r;
        bytes32 s;
        uint8 v;

        //Check the signature length
        if (sig.length != 65) {
            return (address(0));
        }

        // Divide the signature in r, s and v variables
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }

        // Version of signature should be 27 or 28, but 0 and 1 are also possible versions
        if (v < 27) {
            v += 27;
        }

        // If the version is correct return the signer address
        if (v != 27 && v != 28) {
            return (address(0));
        }
        return ecrecover(hash, v, r, s);
    }

    function verify(
        bytes32 root,
        bytes32 leaf,
        bytes32[] memory proof
    ) public pure returns (bool) {
        bytes32 computedHash = leaf;

        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            if (computedHash < proofElement) {
                // Hash(current computed hash + current element of the proof)
                computedHash = keccak256(
                    abi.encodePacked(computedHash, proofElement)
                );
            } else {
                // Hash(current element of the proof + current computed hash)
                computedHash = keccak256(
                    abi.encodePacked(proofElement, computedHash)
                );
            }
        }

        // Check if the computed hash (root) is equal to the provided root
        return computedHash == root;
    }
}