pragma solidity 0.5.11;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/lifecycle/Pausable.sol";
import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./compound/Exponential.sol";
import "./interfaces/IERC1620.sol";
import "./Types.sol";

contract Reports is IERC1620, Exponential, ReentrancyGuard  {

    uint256 reportCount;

    struct Report {
        uint256 Id;
        string content;
        uint256 amount;
        uint256 streamId;
        bool valid;
    }

    /**
     * @notice Reports made per address.
     */
    mapping(address => Report[]) private reports;

    mapping(uint256 => Report) private allReports;
    
    event Reported(address by, uint256 id);
    event ToggledValidity(uint256 id, bool valid);

       /**
     * @notice The amount of interest has been accrued per token address.
     */
    mapping(address => uint256) private earnings;

    /**
     * @notice The percentage fee charged by the contract on the accrued interest.
     */
    Exp public fee;

    /**
     * @notice Counter for new stream ids.
     */
    uint256 public nextStreamId;

    /**
     * @notice The stream objects identifiable by their unsigned integer ids.
     */
    mapping(uint256 => Types.Stream) private streams;

    address owner;

    /*** Modifiers ***/
    /**
     * @dev Throws if the caller is not the sender of the recipient of the stream.
     */
    modifier onlySenderOrRecipient(uint256 streamId) {
        require(
            msg.sender == streams[streamId].sender ||
                msg.sender == streams[streamId].recipient,
            "caller is not the sender or the recipient of the stream"
        );
        _;
    }

    /**
     * @dev Throws if the provided id does not point to a valid stream.
     */
    modifier streamExists(uint256 streamId) {
        require(streams[streamId].isEntity, "stream does not exist");
        _;
    }

    /**
     * @dev Throws if the provided id does not point to a valid stream.
     */
    modifier onlyOwner() {
        require(owner == msg.sender, "stream does not exist");
        _;
    }

    /*** Contract Logic Starts Here */

    constructor() public {
        reportCount = 0;
        nextStreamId = 0;
        owner = msg.sender;
    }

    /*** View Functions ***/

    /**
     * @notice Returns the compounding stream with all its properties.
     * @dev Throws if the id does not point to a valid stream.
     * @param streamId The id of the stream to query.
     * @return The stream object.
     */
    function getStream(uint256 streamId)
        external
        view
        streamExists(streamId)
        returns (
            address sender,
            address recipient,
            uint256 deposit,
            address tokenAddress,
            uint256 startTime,
            uint256 stopTime,
            uint256 remainingBalance,
            uint256 ratePerSecond
        )
    {
        sender = streams[streamId].sender;
        recipient = streams[streamId].recipient;
        deposit = streams[streamId].deposit;
        tokenAddress = streams[streamId].tokenAddress;
        startTime = streams[streamId].startTime;
        stopTime = streams[streamId].stopTime;
        remainingBalance = streams[streamId].remainingBalance;
        ratePerSecond = streams[streamId].ratePerSecond;
    }

    /**
     * @notice Returns either the delta in seconds between `block.timestamp` and `startTime` or
     *  between `stopTime` and `startTime, whichever is smaller. If `block.timestamp` is before
     *  `startTime`, it returns 0.
     * @dev Throws if the id does not point to a valid stream.
     * @param streamId The id of the stream for which to query the delta.
     * @return The time delta in seconds.
     */
    function deltaOf(uint256 streamId)
        public
        view
        streamExists(streamId)
        returns (uint256 delta)
    {
        Types.Stream memory stream = streams[streamId];
        if (block.timestamp <= stream.startTime) return 0;
        if (block.timestamp < stream.stopTime)
            return block.timestamp - stream.startTime;
        return stream.stopTime - stream.startTime;
    }

    function deltaOfReverseStream(uint256 streamId)
        public
        view
        streamExists(streamId)
        returns (uint256 delta)
    {
        Types.Stream memory stream = streams[streamId];
        if (block.timestamp < stream.stopTime)
            return block.timestamp - stream.startTime;
        return stream.stopTime - stream.startTime;
    }

    struct BalanceOfLocalVars {
        MathError mathErr;
        uint256 recipientBalance;
        uint256 withdrawalAmount;
        uint256 senderBalance;
    }

    /**
     * @notice Returns the available funds for the given stream id and address.
     * @dev Throws if the id does not point to a valid stream.
     * @param streamId The id of the stream for which to query the balance.
     * @return The total funds allocated to `receiver` as uint256.
     */
    function balanceOfReverseStream(uint256 streamId)
        public
        view
        streamExists(streamId)
        returns (uint256 balance)
    {
        Types.Stream memory stream = streams[streamId];
        BalanceOfLocalVars memory vars;

        uint256 delta = deltaOfReverseStream(streamId);
        (vars.mathErr, vars.recipientBalance) = mulUInt(
            delta,
            stream.ratePerSecond
        );
        require(
            vars.mathErr == MathError.NO_ERROR,
            "recipient balance calculation error"
        );

        /*
         * If the stream `balance` does not equal `deposit`, it means there have been withdrawals.
         * We have to subtract the total amount withdrawn from the amount of money that has been
         * streamed until now.
         */
        if (stream.deposit > stream.remainingBalance) {
            (vars.mathErr, vars.withdrawalAmount) = subUInt(
                stream.deposit,
                stream.remainingBalance
            );

            assert(vars.mathErr == MathError.NO_ERROR);
            (vars.mathErr, vars.recipientBalance) = subUInt(
                vars.recipientBalance,
                vars.withdrawalAmount
            );
            /* `withdrawalAmount` cannot and should not be bigger than `recipientBalance`. */
            assert(vars.mathErr == MathError.NO_ERROR);
        }

        return vars.recipientBalance;
    }

    /**
     * @notice Returns the available funds for the given stream id and address.
     * @dev Throws if the id does not point to a valid stream.
     * @param streamId The id of the stream for which to query the balance.
     * @param who The address for which to query the balance.
     * @return The total funds allocated to `who` as uint256.
     */
    function balanceOf(uint256 streamId, address who)
        public
        view
        streamExists(streamId)
        returns (uint256 balance)
    {
        Types.Stream memory stream = streams[streamId];
        BalanceOfLocalVars memory vars;

        uint256 delta = deltaOf(streamId);
        (vars.mathErr, vars.recipientBalance) = mulUInt(
            delta,
            stream.ratePerSecond
        );
        require(
            vars.mathErr == MathError.NO_ERROR,
            "recipient balance calculation error"
        );

        /*
         * If the stream `balance` does not equal `deposit`, it means there have been withdrawals.
         * We have to subtract the total amount withdrawn from the amount of money that has been
         * streamed until now.
         */
        if (stream.deposit > stream.remainingBalance) {
            (vars.mathErr, vars.withdrawalAmount) = subUInt(
                stream.deposit,
                stream.remainingBalance
            );
            assert(vars.mathErr == MathError.NO_ERROR);
            (vars.mathErr, vars.recipientBalance) = subUInt(
                vars.recipientBalance,
                vars.withdrawalAmount
            );
            /* `withdrawalAmount` cannot and should not be bigger than `recipientBalance`. */
            assert(vars.mathErr == MathError.NO_ERROR);
        }

        if (who == stream.recipient) return vars.recipientBalance;
        if (who == stream.sender) {
            (vars.mathErr, vars.senderBalance) = subUInt(
                stream.remainingBalance,
                vars.recipientBalance
            );
            /* `recipientBalance` cannot and should not be bigger than `remainingBalance`. */
            assert(vars.mathErr == MathError.NO_ERROR);
            return vars.senderBalance;
        }
        return 0;
    }

    /*** Public Effects & Interactions Functions ***/

    struct CreateStreamLocalVars {
        MathError mathErr;
        uint256 duration;
        uint256 ratePerSecond;
    }

    /**
     * @notice Creates a new reverse stream stream funded by `msg.sender` and paid towards `msg.sender`.
     * @dev Throws if paused.
     *  Throws if the deposit is 0.
     *  Throws if the start time is before `block.timestamp`.
     *  Throws if the stop time is before the start time.
     *  Throws if the duration calculation has a math error.
     *  Throws if the deposit is smaller than the duration.
     *  Throws if the deposit is not a multiple of the duration.
     *  Throws if the rate calculation has a math error.
     *  Throws if the next stream id calculation has a math error.
     *  Throws if the contract is not allowed to transfer enough tokens.
     *  Throws if there is a token transfer failure.
     * @param deposit The amount of money to be streamed.
     * @param tokenAddress The ERC20 token to use as streaming currency.
     * @param stopTime The unix timestamp for when the stream stops.
     * @return The uint256 id of the newly created stream.
     */
    function createReverseStream(
        uint256 deposit,
        address tokenAddress,
        uint256 stopTime
    ) public returns (uint256) {
        createStream(
            msg.sender,
            deposit,
            tokenAddress,
            block.timestamp,
            stopTime
        );
    }

    /**
     * @notice Creates a new  stream stream funded by `msg.sender` and paid towards `msg.sender`.
     * @dev Throws if paused.
     *  Throws if the deposit is 0.
     *  Throws if the start time is before `block.timestamp`.
     *  Throws if the stop time is before the start time.
     *  Throws if the duration calculation has a math error.
     *  Throws if the deposit is smaller than the duration.
     *  Throws if the deposit is not a multiple of the duration.
     *  Throws if the rate calculation has a math error.
     *  Throws if the next stream id calculation has a math error.
     *  Throws if the contract is not allowed to transfer enough tokens.
     *  Throws if there is a token transfer failure.
     * @param recipient The address towards which the money is streamed.
     * @param deposit The amount of money to be streamed.
     * @param tokenAddress The ERC20 token to use as streaming currency.
     * @param startTime The unix timestamp for when the stream starts.
     * @param stopTime The unix timestamp for when the stream stops.
     * @return The uint256 id of the newly created stream.
     */
    function createStream(
        address recipient,
        uint256 deposit,
        address tokenAddress,
        uint256 startTime,
        uint256 stopTime
    ) public returns (uint256) {
        // require(recipient != address(0x00), "stream to the zero address");
        // require(recipient != address(this), "stream to the contract itself");
        // require(recipient != msg.sender, "stream to the caller");
        require(deposit > 0, "deposit is zero");
        // require(
        //     startTime >= block.timestamp,
        //     "start time before block.timestamp"
        // );

        // require(stopTime > startTime, "stop time before the start time");

        CreateStreamLocalVars memory vars;
        (vars.mathErr, vars.duration) = subUInt(stopTime, startTime);
        /* `subUInt` can only return MathError.INTEGER_UNDERFLOW but we know `stopTime` is higher than `startTime`. */
        assert(vars.mathErr == MathError.NO_ERROR);

        /* Without this, the rate per second would be zero. */
        require(deposit >= vars.duration, "deposit smaller than time delta");

        /* This condition avoids dealing with remainders */
        // require(
        //     deposit % vars.duration == 0,
        //     "deposit not multiple of time delta"
        // );

        (vars.mathErr, vars.ratePerSecond) = divUInt(deposit, vars.duration);
        /* `divUInt` can only return MathError.DIVISION_BY_ZERO but we know `duration` is not zero. */
        assert(vars.mathErr == MathError.NO_ERROR);

        /* Create and store the stream object. */
        uint256 streamId = nextStreamId;
        streams[streamId] = Types.Stream({
            remainingBalance: deposit,
            deposit: deposit,
            isEntity: true,
            ratePerSecond: vars.ratePerSecond,
            recipient: recipient,
            sender: msg.sender,
            startTime: startTime,
            stopTime: stopTime,
            tokenAddress: tokenAddress
        });

        /* Increment the next stream id. */
        (vars.mathErr, nextStreamId) = addUInt(nextStreamId, uint256(1));
        require(
            vars.mathErr == MathError.NO_ERROR,
            "next stream id calculation error"
        );

        require(
            ERC20Burnable(tokenAddress).transferFrom(
                msg.sender,
                address(this),
                deposit
            ),
            "token transfer failure"
        );
        emit CreateStream(
            streamId,
            msg.sender,
            recipient,
            deposit,
            tokenAddress,
            startTime,
            stopTime
        );
        return streamId;
    }

    struct WithdrawFromStreamLocalVars {
        MathError mathErr;
    }

    /**
     * @notice Withdraws from the contract to the recipient's account.
     * @dev Throws if the id does not point to a valid stream.
     *  Throws if the caller is not the sender or the recipient of the stream.
     *  Throws if the amount exceeds the available balance.
     *  Throws if there is a token transfer failure.
     * @param streamId The id of the stream to withdraw tokens from.
     * @param amount The amount of tokens to withdraw.
     * @return bool true=success, otherwise false.
     */
    function withdrawFromStream(uint256 streamId, uint256 amount)
        external
        nonReentrant
        streamExists(streamId)
        onlySenderOrRecipient(streamId)
        returns (bool)
    {
        require(amount > 0, "amount is zero");
        Types.Stream memory stream = streams[streamId];
        WithdrawFromStreamLocalVars memory vars;

        uint256 balance = balanceOf(streamId, stream.recipient);
        require(balance >= amount, "amount exceeds the available balance");

        (vars.mathErr, streams[streamId].remainingBalance) = subUInt(
            stream.remainingBalance,
            amount
        );
        /**
         * `subUInt` can only return MathError.INTEGER_UNDERFLOW but we know that `remainingBalance` is at least
         * as big as `amount`.
         */
        assert(vars.mathErr == MathError.NO_ERROR);

        if (streams[streamId].remainingBalance == 0) delete streams[streamId];

        require(
            ERC20Burnable(stream.tokenAddress).transfer(
                stream.recipient,
                amount
            ),
            "token transfer failure"
        );
        emit WithdrawFromStream(streamId, stream.recipient, amount);
    }

    /**
     * @notice Cancels the stream and transfers the tokens back on a pro rata basis.
     * @dev Throws if the id does not point to a valid stream.
     *  Throws if the caller is not the sender or the recipient of the stream.
     *  Throws if there is a token transfer failure.
     * @param streamId The id of the stream to cancel.
     * @return bool true=success, otherwise false.
     */
    function cancelStream(uint256 streamId)
        external
        nonReentrant
        streamExists(streamId)
        onlyOwner()
        returns (bool)
    {
        Types.Stream memory stream = streams[streamId];
        uint256 senderBalance = balanceOf(streamId, stream.sender);
        uint256 recipientBalance = balanceOf(streamId, stream.recipient);

        delete streams[streamId];

        ERC20Burnable token = ERC20Burnable(stream.tokenAddress);
        if (recipientBalance > 0)
            require(
                token.transfer(stream.recipient, recipientBalance),
                "recipient token transfer failure"
            );
        if (senderBalance > 0)
            require(
                token.transfer(stream.sender, senderBalance),
                "sender token transfer failure"
            );

        emit CancelStream(
            streamId,
            stream.sender,
            stream.recipient,
            senderBalance,
            recipientBalance
        );
    }

    // TODO make it permissioned to only the receiver address
    function Close(uint256 streamId)
        external
        nonReentrant
        streamExists(streamId)
        returns (bool) 
    {
        uint256 remainingBalance = balanceOfReverseStream(streamId);
        Types.Stream memory stream = streams[streamId];
        delete streams[streamId];
        ERC20Burnable token = ERC20Burnable(stream.tokenAddress);

        bool valid = toggleReportValidity(streamId);
        token.burn(remainingBalance);

        return valid
    }
    
    function reportEvent(
        string memory _content,
        uint256 deposit,
        address tokenAddress,
        uint256 stopTime
    ) public returns (uint256) {
        Report memory report = Report(reportCount, _content, nextStreamId, deposit, true);
        reports[msg.sender].push(
            report
        );

        allReports[reportCount] = report;

        createReverseStream(
            deposit,
            tokenAddress,
            stopTime
        );

        reportCount++;
        emit Reported(msg.sender, reportCount);
    }

    function toggleReportValidity(
        uint256 _id
    ) public returns (bool) {
        Report memory _report = allReports[_id];
        _report.valid = !_report.valid;
        allReports[_id] = _report;

        emit ToggledValidity(_id, _report.valid);

        return _report.valid;
    }

    function getUserReports(address user) public view returns (Report[] memory){
        return reports[user];
    }

    function getAllReports() public view returns (Report[] memory){
        Report[] memory reportArr = new Report[](reportCount);

        for (uint i=0; i<reportCount; i++){
            reportArr[i] = allReports[i];
        }

        return reportArr;
    }
}