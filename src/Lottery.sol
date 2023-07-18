// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "@openzeppelin-upgrade/contracts/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin-upgrade/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgrade/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgrade/contracts/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin-upgrade/contracts/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin-upgrade/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-upgrade/contracts/utils/cryptography/MerkleProofUpgradeable.sol";

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "./LotteryToken.sol";
import "./WrappedLotteryToken.sol";
import "./SortLibrary.sol";

abstract contract Lottery is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeMathUpgradeable for uint256;

    struct Ticket {
        uint256 tokenId;
        uint256 depositorId;
        uint256 wrappedTokenId;
        uint256 rewardAmount;
    }

    uint256 internal constant DEPOSIT_PERIOD = 7 * 86400; // Duration of the deposit period in seconds
    uint256 internal constant BREAK_PERIOD = 7 * 86400; // Duration of the break period in seconds

    mapping(address => Ticket) public tickets; // Ticket for users
    SelectLibrary.Depositor[] public depositors; // Depositor list

    bytes32 public rootHash; // root hash for whitelist
    uint8 public rentTokenFee; // Rent fee for a NFT token owner
    uint8 public protocolFee; // Lottery fee to be rewarded to Lottery contract onwer
    uint256 public numberOfWinners; // Number of winners in each period
    uint256 public rentAmount; // Rent amount for NFT ticket
    uint256 public lotteryStartTime; // start timestamp for the current lottery

    LotteryToken private token; // NFT token for owner
    WrappedLotteryToken private wrappedToken; // Wrapped token for borrower

    uint256 internal totalDepositAmount; // Total deposit amount in the current lottery
    uint256 internal numberOfDepositors; // Total Depositor number in the current lottery
    uint256 internal accumulatedProtocolReward; // Protocol fee Reward
    bool internal winnersSelected;

    event JoinedLottery(uint256 tokenId, address indexed buyer, uint256 amount);
    event StartedLottery(uint256 timestamp);
    event WinnerSelected(address[] winners);
    event BorrowedTicket(
        address indexed borrower,
        uint256 tokenId,
        uint256 wrappedTokenId
    );
    event ClaimedReward(uint256 amount);

    error NotWhitelistedUser();
    error LotteryNotEnded();
    error LotteryNotInDepositPeriod();
    error LotteryNotInBreakPeriod();
    error InsufficientRentAmount();
    error NotRentableForOwner();
    error AlreadyRentTicket();
    error InvalidTicketForOwner();
    error NotWinner();
    error NotAvailableReward();
    error AlreadyClaimedReward();
    error AlreadyWinnerSelected();
    error NoParticipantsInLottery();
    error InvalidNumberOfWinners();
    error NotValidRootHash();
    error NotSelectedWinners();

    /**
     * @dev Modifier to check that the current block timestamp is within the deposit period.
     * @notice If the current block timestamp is outside the deposit period, the function call will revert.
     */
    modifier onlyDuringDepositPeriod() {
        checkInDepsoitPeriod();
        _;
    }

    /**
     * @dev Modifier to check that the current block timestamp is within the break period.
     * @notice If the current block timestamp is outside the break period, the function call will revert.
     */
    modifier onlyDuringBreakPeriod() {
        checkInBreakPeriod();
        _;
    }

    /**
     * @dev Modifier to check that the lottery has ended.
     * @notice This modifier can be used to restrict the execution of a function to after the lottery has ended.
     * @notice If the current block timestamp is before the lottery end time, the function call will revert.
     */
    modifier onlyLotteryEnded() {
        checkLotteryEnded();
        _;
    }

    /**
     * @dev Initializes the contract with the specified parameters.
     * @param _protocolFee The percentage of the total reward that will be charged as protocol fee.
     * @param _rentTokenFee The percentage of the total pot that will be charged as rent token fee.
     * @param _rentAmount The amount of rent tokens that each participant must hold to participate in the lottery.
     * @param _numberOfWinners The number of winners in the lottery draw.
     * @notice This function can only be called once after contract deployment.
     * @notice The contract owner will be set to the sender of the `initialize` transaction.
     */
    function initialize(
        uint8 _protocolFee,
        uint8 _rentTokenFee,
        uint256 _rentAmount,
        uint256 _numberOfWinners
    ) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();

        numberOfWinners = _numberOfWinners;
        protocolFee = _protocolFee;
        rentTokenFee = _rentTokenFee;
        rentAmount = _rentAmount;

        token = new LotteryToken(msg.sender, "NFT Token", "NFT_TOKEN");
        wrappedToken = new WrappedLotteryToken(
            msg.sender,
            "Wrapped NFT Token",
            "WRAPPED_NFT_TOKEN"
        );

        transferOwnership(msg.sender);
    }

    /**
     * @dev Starts a new lottery by clearing the depositor list, updating the root hash for whitelist users, 
            setting the lottery start time, clearing the total deposit amount.
     * @param _rootHash The new root hash for whitelist users.
     */
    function startLottery(
        bytes32 _rootHash
    ) external onlyOwner onlyLotteryEnded {
        // check if rootHash is valid
        if (rootHash == bytes32(0)) revert NotValidRootHash();

        // clear depositor list
        delete depositors;

        // update rootHash for whitelist users
        rootHash = _rootHash;

        // start lottery and set start time as now
        lotteryStartTime = block.timestamp;

        // clear totalDeposit amount for new lottery
        totalDepositAmount = 0;

        // set winner flag as false and available to decide winner for the current lottery
        winnersSelected = false;

        emit StartedLottery(lotteryStartTime);
    }

    /**
     * @dev Selects the winners of the current lottery and distributes the reward among them.
     *
     * Requirements:
     * - Only the contract owner can call this function.
     * - The function can only be called during the deposit period.
     * - The function can only be called once per lottery.
     * - There must be at least one depositor in the current lottery.
     * - The number of winners must be less than or equal to the number of depositors.
     */
    function decideWinner()
        external
        onlyOwner
        onlyDuringDepositPeriod
        nonReentrant
    {
        // if already selected winner, should revert
        if (winnersSelected) revert AlreadyWinnerSelected();

        // if there is no depositors in the current lottery, should revert
        if (numberOfDepositors == 0) revert NoParticipantsInLottery();

        // if depositors are less than winners, should revert
        if (numberOfWinners > numberOfDepositors)
            revert InvalidNumberOfWinners();

        address[] memory selectedWinners = new address[](numberOfWinners);

        // Choose winner using QuickSelect algorithm
        SelectLibrary.quickselect(
            depositors,
            rootHash,
            0,
            numberOfDepositors - 1,
            numberOfWinners,
            selectedWinners
        );

        // calculates the reward amount for the winners by subtracting the protocol fee from the total deposit amount.
        uint256 rewardAmount = totalDepositAmount.mul(100 - protocolFee).div(
            100
        );

        // calculates the reward amount per winner.
        uint256 rewardAmountPerUser = rewardAmount.div(numberOfWinners);

        // updates the reward amount for each winner's ticket.
        for (uint256 i; i != numberOfWinners; ++i) {
            Ticket storage ticket = tickets[selectedWinners[i]];
            ticket.rewardAmount += rewardAmountPerUser;
        }

        // calculates the accumulated protocol reward by subtracting the reward amount from the total deposit amount.
        accumulatedProtocolReward += totalDepositAmount.sub(rewardAmount);

        // sets the winnersSelected flag to true to indicate that the winners have been selected.
        winnersSelected = true;

        emit WinnerSelected(selectedWinners);
    }

    /**
     * @dev Allows a user to join the current lottery by depositing ETH and receiving a ticket.
     *
     * If the user is not already a depositor, a new ticket will be minted and added to the user's account.
     * If the user has already deposited in a previous lottery, their existing ticket will be updated with the new deposit amount.
     * If the user is a whitelisted user, they can join the lottery without depositing any ETH.
     *
     * Requirements:
     * - The function can only be called during the deposit period.
     */
    function joinLottery(
        bytes32[] calldata data
    ) external payable nonReentrant onlyDuringDepositPeriod {
        // check if user transfer the valid ETH's amount
        if (msg.value == 0) {
            // whitelist user doesn't need to send ETH
            if (!verifyWhitelistUser(data, msg.sender))
                revert NotWhitelistedUser();
        }

        // get ticket for user
        Ticket storage ticket = tickets[msg.sender];

        // check if user already joined to the lottery portal once
        if (ticket.tokenId == 0) {
            // increment depositor count;
            numberOfDepositors++;

            // add new depositor in the depositor list
            depositors.push(SelectLibrary.Depositor(msg.sender, msg.value));

            // mint new NFT token for user
            uint256 tokenId = token.mintToken(msg.sender);

            ticket.tokenId = tokenId;
            ticket.depositorId = depositors.length;
        } else {
            // check if user already has joined to the previous lottery and get reward, and
            if (ticket.rewardAmount > 0) _claimReward(msg.sender);

            uint256 depositorIndex = ticket.depositorId - 1;

            // check if ticket is already created and owner didn't deposit yet in the current lottery draw.
            if (depositorIndex >= 0 && depositorIndex < depositors.length) {
                SelectLibrary.Depositor storage depositor = depositors[
                    depositorIndex
                ];

                if (depositor.user == msg.sender) {
                    // increase the deposited amount for user
                    depositor.amount += msg.value;
                } else {
                    // increment depositor count;
                    numberOfDepositors++;

                    depositors.push(
                        SelectLibrary.Depositor(msg.sender, msg.value)
                    );

                    // update token's deposit id
                    ticket.depositorId = depositors.length;
                }
            } else {
                // increment depositor count;
                numberOfDepositors++;

                depositors.push(SelectLibrary.Depositor(msg.sender, msg.value));
                ticket.depositorId = depositors.length;
            }
        }

        // increase the deposited amount for current lottery
        totalDepositAmount += msg.value;

        emit JoinedLottery(ticket.tokenId, msg.sender, msg.value);
    }

    /**
     * @dev Allows a user to rent a ticket from another user by paying the rent amount in ETH.
     *
     * Requirements:
     * - The function can only be called during the deposit period.
     * - The user must pay an amount of ETH equal or greater than the rent amount.
     * - The user cannot rent their own ticket.
     * - The user cannot rent a ticket if they already have a rented ticket.
     * - The owner of the ticket must have a valid NFT token.
     *
     * Effects:
     * - Mints a new wrapped NFT token for the borrower and sets the owner to the borrower's address.
     * - Sets the wrapped token ID on the owner's ticket to the ID of the newly minted wrapped token.
     * - Emits a `BorrowedTicket` event with the borrower's address, the ticket ID, and the wrapped token ID.
     */
    function rentTicket(
        address _owner
    ) external payable nonReentrant onlyDuringDepositPeriod {
        // check if paying ETH is bigger than rent amount
        if (msg.value < rentAmount) revert InsufficientRentAmount();

        // check if user has already participated in lottery
        if (_owner == msg.sender) revert NotRentableForOwner();

        // check if user has already rent
        if (wrappedToken.tokenIdOf(msg.sender) > 0) revert AlreadyRentTicket();

        // check if owner has his ticket
        if (token.tokenIdOf(_owner) == 0) revert InvalidTicketForOwner();

        // mint wrapped nft token for borrower
        uint256 wrappedTokenId = wrappedToken.mintToken(_owner, msg.sender);

        // get the nft ticket and update wrapped token id
        Ticket storage ticket = tickets[_owner];
        ticket.wrappedTokenId = wrappedTokenId;

        emit BorrowedTicket(msg.sender, ticket.tokenId, wrappedTokenId);
    }

    function claimReward() external returns (uint256) {
        return _claimReward(msg.sender);
    }

    /**
     * @dev Allows a user to claim their reward for a winning ticket and/or for borrowing a ticket during the lottery deposit period.
     *
     * If the user has rented a ticket, the borrower's reward is subtracted from the owner's reward, and the borrower receives their reward amount in ETH. If the user has not rented a ticket, the owner receives their full reward amount in ETH.
     *
     * Requirements:
     * - The function can only be called once per ticket.
     * - The function can only be called during the claim period.
     * - The user must have a valid NFT token linked to the wrapped token.
     * - The user must have a reward amount greater than 0.
     * @param _user The address of the user claiming the reward.
     * @return The amount of ETH transferred as a reward.
     */
    function _claimReward(address _user) public nonReentrant returns (uint256) {
        // check if winners are selected in the current lottery draw
        if (winnersSelected == false) revert NotSelectedWinners();

        // get user wrapped token id
        uint256 borrowTokenId = wrappedToken.tokenIdOf(_user);

        // get owner of nft token linked to the wrapped token
        address owner = wrappedToken.originOwnerOf(borrowTokenId);

        // get owner's ticket
        Ticket storage ticket = tickets[owner];

        // check if user has a borrow token
        if (borrowTokenId > 0) {
            // check if period is in break for getting reward
            checkInBreakPeriod();

            // check if user has reward
            if (ticket.rewardAmount == 0) revert NotAvailableReward();

            // calculate borrower's reward
            uint256 borrowerReward = ticket
                .rewardAmount
                .mul(100 - rentTokenFee)
                .div(100);

            ticket.rewardAmount -= borrowerReward;

            // burn the borrower's wrapped token
            wrappedToken.burnToken(_user);

            // transfer reward to borrower
            payable(_user).transfer(borrowerReward);
        }

        // check if ticket is win or has reward
        if (ticket.rewardAmount == 0) revert AlreadyClaimedReward();

        uint256 rewardAmount;

        // check if someone has borrown the ticket
        if (ticket.wrappedTokenId > 0) {
            // check if lottery is still in break period
            if (isLotteryEnded()) {
                // owner burn the borrower's wrapped token and get all the reward
                rewardAmount = ticket.rewardAmount;
                ticket.rewardAmount = 0;

                wrappedToken.burnToken(
                    wrappedToken.ownerOf(ticket.wrappedTokenId)
                );
            } else {
                // owner get his reward except the borrower reward
                rewardAmount = ticket.rewardAmount.mul(rentTokenFee).div(100);
                ticket.rewardAmount -= rewardAmount;
            }
        } else {
            // owner hasn't borrower and get his reward
            rewardAmount = ticket.rewardAmount;
            // clear reward amount
            ticket.rewardAmount = 0;
        }

        // transfer reward to user
        payable(_user).transfer(rewardAmount);

        emit ClaimedReward(rewardAmount);

        return rewardAmount;
    }

    /**
     * @dev Allows the contract owner to withdraw the accumulated protocol reward in ETH.
     *
     * Requirements:
     * - The function can only be called by the contract owner.
     */
    function withdrawProtocolReward() external onlyOwner returns (uint256) {
        payable(owner()).transfer(accumulatedProtocolReward);

        return accumulatedProtocolReward;
    }

    /**
     * @dev Allows the contract owner to withdraw a specified amount of the accumulated protocol reward in ETH.
     *
     * Requirements:
     * - The function can only be called by the contract owner.
     *
     * @param _amount The amount of ETH to withdraw from the accumulated protocol reward.
     */
    function withdrawProtocolReward(
        uint256 _amount
    ) external onlyOwner nonReentrant returns (uint256) {
        uint256 balance = address(owner()).balance;

        if (_amount > balance) {
            _amount = balance;
            accumulatedProtocolReward -= _amount;
        }

        payable(owner()).transfer(_amount);

        return accumulatedProtocolReward;
    }

    /**
     * @dev Allows the contract owner to set the rent token fee percentage.
     *
     * Requirements:
     * - The function can only be called by the contract owner.
     * - The lottery must have ended.
     *
     * @param _rentTokenFee The new rent token fee percentage.
     */
    function setRentTokenFee(
        uint8 _rentTokenFee
    ) external onlyOwner onlyLotteryEnded {
        rentTokenFee = _rentTokenFee;
    }

    /**
     * @dev Allows the contract owner to set the protocol fee percentage.
     *
     * Requirements:
     * - The function can only be called by the contract owner.
     * - The lottery must have ended.
     *
     * @param _protocolFee The new protocol fee percentage.
     */
    function setProtocolFee(
        uint8 _protocolFee
    ) external onlyOwner onlyLotteryEnded {
        protocolFee = _protocolFee;
    }

    /**
     * @dev Allows the contract owner to set the number of winners for the lottery.
     *
     * Requirements:
     * - The function can only be called by the contract owner.
     * - The lottery must have ended.
     *
     * @param _numberOfWinners The new number of winners.
     */
    function setNumberOfWinners(
        uint256 _numberOfWinners
    ) external onlyOwner onlyLotteryEnded {
        numberOfWinners = _numberOfWinners;
    }

    /**
     * @dev Checks whether the lottery has ended.
     *
     * Requirements:
     * - The current time must be after the end of the deposit period and the break period.
     *
     * Throws:
     * - `LotteryNotEnded` if the lottery has not ended yet.
     */
    function checkLotteryEnded() internal view virtual {
        if (lotteryStartTime < block.timestamp + DEPOSIT_PERIOD + BREAK_PERIOD)
            revert LotteryNotEnded();
    }

    function isLotteryEnded() internal view returns (bool) {
        if (lotteryStartTime < block.timestamp + DEPOSIT_PERIOD + BREAK_PERIOD)
            return false;

        return true;
    }

    /**
     * @dev Checks whether the current time is within the deposit period.
     *
     * Requirements:
     * - The current time must be between the start of the deposit period and the end of the deposit period.
     *
     * Throws:
     * - `LotteryNotInDepositPeriod` if the current time is not within the deposit period.
     */
    function checkInDepsoitPeriod() internal view virtual {
        uint256 currentTime = block.timestamp;

        if (
            currentTime < lotteryStartTime ||
            currentTime > lotteryStartTime + DEPOSIT_PERIOD
        ) revert LotteryNotInDepositPeriod();
    }

    /**
     * @dev Checks whether the current time is within the break period.
     *
     * Requirements:
     * - The current time must be between the end of the deposit period and the end of the break period.
     *
     * Throws:
     * - `LotteryNotInBreakPeriod` if the current time is not within the break period.
     */
    function checkInBreakPeriod() internal view virtual {
        uint256 currentTime = block.timestamp;

        if (
            currentTime < lotteryStartTime + DEPOSIT_PERIOD ||
            currentTime > lotteryStartTime + DEPOSIT_PERIOD + BREAK_PERIOD
        ) revert LotteryNotInBreakPeriod();
    }

    /**
     * @dev Verifies whether a user is on the whitelist.
     *
     * @param proof The Merkle proof for the user.
     * @param user The address of the user.
     * @return `true` if the user is on the whitelist, `false` otherwise.
     */
    function verifyWhitelistUser(
        bytes32[] memory proof,
        address user
    ) internal view returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(user));
        return MerkleProofUpgradeable.verify(proof, rootHash, leaf);
    }
}
