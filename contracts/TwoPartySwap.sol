// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "hardhat/console.sol";

contract TwoPartySwap {

    /**
    The Swap struct keeps track of participants and swap details
     */
    struct Swap {
        // assetEscrower: who escrows the asset (Alice in diagram)
        address payable assetEscrower;
        // premiumEscrower: who escrows the premium (Bob in diagram)
        address payable premiumEscrower;
        // hashLock: the hash of a secret, which only the assetEscrower kblock.timestamps
        bytes32 hashLock;
        // assetAddress: the ERC20 Token's address, which will be used to access accounts
        address assetAddress;
    }

    /**
    The Asset struct keeps track of the escrowed Asset
     */
    struct Asset {
        // expected: the agreed-upon amount to be escrowed
        uint expected;
        // current: the current amount of the asset that is escrowed in the swap.
        uint current;
        // deadline: the time before which the person escrowing their asset must do so
        uint deadline;
        // timeout: the maximum time the protocol can take, which assumes everything
        // goes to plan.
        uint timeout;
    }

    /**
    The Premium struct keeps track of the escrowed premium.
     */
    struct Premium {
        // expected: the agreed-upon amount to be escrowed as a premium
        uint expected;
        // current: the current amount of the premium that is escrowed in the swap
        uint current;
        // deadline: the time before which the person escrowing their premium must do so
        uint deadline;
    }

    /**
    Mappings that store our swap details. This contract stores multiple swaps; you can access
    information about a specific swap by using its hashLock as the key to the appropriate mapping.
     */
    mapping(bytes32 => Swap) public swaps;
    mapping(bytes32 => Asset) public assets;
    mapping(bytes32 => Premium) public premiums;

    /**
    SetUp: this event should emit when a swap is successfully setup.
     */
    event SetUp(
        address payable assetEscrower,
        address payable premiumEscrower,
        uint expectedPremium,
        uint expectedAsset,
        uint startTime,
        uint premiumDeadline,
        uint assetDeadline,
        uint assetTimeout
    );

    /**
    PremiumEscrowed: this event should emit when the premiumEscrower successfully escrows the premium
     */
    event PremiumEscrowed (
        address messageSender,
        uint amount,
        address transferFrom,
        address transferTo,
        uint currentPremium,
        uint currentAsset
    );

    /**
    AssetEscrowed: this event should emit  when the assetEscrower successfully escrows the asset
     */
    event AssetEscrowed (
        address messageSender,
        uint amount,
        address transferFrom,
        address transferTo,
        uint currentPremium,
        uint currentAsset
    );

    /**
    AssetRedeemed: this event should emit when the assetEscrower successfully escrows the asset
     */
    event AssetRedeemed(
        address messageSender,
        uint amount,
        address transferFrom,
        address transferTo,
        uint currentPremium,
        uint currentAsset
    );

    /**
    PremiumRefunded: this event should emit when the premiumEscrower successfully gets their premium refunded
     */
    event PremiumRefunded(
        address messageSender,
        uint amount,
        address transferFrom,
        address transferTo,
        uint currentPremium,
        uint currentAsset
    );

    /**
    PremiumRedeemed: this event should emit when the counterparty breaks the protocol
    and the assetEscrower redeems the  premium for breaking the protocol 
     */
    event PremiumRedeemed(
        address messageSender,
        uint amount,
        address transferFrom,
        address transferTo,
        uint currentPremium,
        uint currentAsset
    );

    /**
    AssetRefunded: this event should emit when the counterparty breaks the protocol 
    and the assetEscrower succesffully gets their asset refunded
     */
    event AssetRefunded(
        address messageSender,
        uint amount,
        address transferFrom,
        address transferTo,
        uint currentPremium,
        uint currentAsset
    );

    /**
    TODO: using modifiers for your require statements is best practice,
    but we do not require you to do so
    */ 
    modifier canSetup(bytes32 hashLock) {
        require(swaps[hashLock].assetEscrower == address(0));
        require(swaps[hashLock].premiumEscrower == address(0));
        require(swaps[hashLock].hashLock == bytes32(0));
        require(swaps[hashLock].assetAddress == address(0));
        _;
    }

    modifier canEscrowPremium(bytes32 hashLock) {
        require(msg.sender == swaps[hashLock].premiumEscrower);
        require(premiums[hashLock].current != premiums[hashLock].expected);
        require(ERC20(swaps[hashLock].assetAddress).balanceOf(msg.sender) >= premiums[hashLock].expected);
        require(block.timestamp < premiums[hashLock].deadline);
        _;
    }

    modifier canEscrowAsset(bytes32 hashLock) {
        require(msg.sender == swaps[hashLock].assetEscrower);
        require(premiums[hashLock].current == premiums[hashLock].expected);
        require(assets[hashLock].current != assets[hashLock].expected);
        require(ERC20(swaps[hashLock].assetAddress).balanceOf(msg.sender) >= assets[hashLock].expected);
        require(block.timestamp < assets[hashLock].deadline);
        _;
    }

    modifier canRedeemAsset(bytes32 preimage, bytes32 hashLock) {
        require(msg.sender != swaps[hashLock].assetEscrower);
        require(sha256(abi.encode(preimage)) == hashLock); // check preimage
        require(assets[hashLock].current == assets[hashLock].expected);
        require(block.timestamp < assets[hashLock].deadline);
        _;
    }

    modifier canRefundAsset(bytes32 hashLock) {
        // require(msg.sender == swaps[hashLock].assetEscrower);
        require(premiums[hashLock].current == premiums[hashLock].expected); // if premium not escrowed
        require(assets[hashLock].current == assets[hashLock].expected); // if asset not escrowed
        require(block.timestamp > assets[hashLock].deadline); // too early
        _;
    }

    modifier canRefundPremium(bytes32 hashLock) {
        require(premiums[hashLock].expected == premiums[hashLock].current); // if premium not escrowed
        require(assets[hashLock].current != assets[hashLock].expected); // if already escrowed
        require(block.timestamp > assets[hashLock].timeout); // too early
        _;
    }

    modifier canRedeemPremium(bytes32 hashLock) {
        require(premiums[hashLock].current == premiums[hashLock].expected); // premium escrowed
        require(assets[hashLock].expected != 0); // asset amount = 0
        require(block.timestamp > assets[hashLock].timeout); // wait for time out
        _;
    }
   
    /**
    setup is called to initialize an instance of a swap in this contract. 
    Due to storage constraints, the various parts of the swap are spread 
    out between the three different mappings above: swaps, assets, 
    and premiums.
    */
    function setup(
        uint expectedAssetEscrow,
        uint expectedPremiumEscrow,
        address payable assetEscrower,
        address payable premiumEscrower,
        address assetAddress,
        bytes32 hashLock,
        uint startTime,
        bool firstAssetEscrow,
        uint delta
    )
        public 
        payable 
        canSetup(hashLock) 
    {
        //TODO
        // create struct to initialize
        swaps[hashLock] = Swap(
            assetEscrower,
            premiumEscrower,
            hashLock,
            assetAddress
        );
        assets[hashLock] = Asset(
            expectedAssetEscrow,
            0, // initialize with 0
            startTime + delta,
            startTime + 2 * delta // * 2 since there's two parties
        );
        premiums[hashLock] = Premium(
            expectedPremiumEscrow,
            0,
            startTime + delta
        );

        // emit the event
        if(firstAssetEscrow == true){
            emit SetUp(
                assetEscrower,
                premiumEscrower,
                expectedPremiumEscrow,
                expectedAssetEscrow,
                startTime,
                startTime + 2 * delta,
                startTime + 3 * delta,
                startTime + 6 * delta
            );
        } else { // if not the escrow
            emit SetUp(
                assetEscrower,
                premiumEscrower,
                expectedPremiumEscrow,
                expectedAssetEscrow,
                startTime,
                startTime + 1 * delta,
                startTime + 4 * delta,
                startTime + 5 * delta
            );
        }
    }

    /**
    The premium escrower has to escrow their premium for the protocol to succeed.
    */
    function escrowPremium(bytes32 hashLock)
        public
        payable
        canEscrowPremium(hashLock)
    {
        //TODO
        ERC20(swaps[hashLock].assetAddress).transferFrom(
            swaps[hashLock].premiumEscrower,
            address(this),
            premiums[hashLock].expected
        );
        // update current premium
        premiums[hashLock].current += premiums[hashLock].expected;

        // deduct
        emit PremiumEscrowed(
            swaps[hashLock].premiumEscrower,
            premiums[hashLock].expected,
            swaps[hashLock].premiumEscrower,
            address(this), // transfer to this contract
            premiums[hashLock].current,
            assets[hashLock].current
        );
    }
    
    /**
    The asset escrower has to escrow their premium for the protocol to succeed
    */
    function escrowAsset(bytes32 hashLock) 
        public 
        payable 
        canEscrowAsset(hashLock) 
    {
        //TODO
        ERC20(swaps[hashLock].assetAddress).transferFrom(
            msg.sender,
            address(this),
            assets[hashLock].expected
        );

        // update current asset
        
        assets[hashLock].current = assets[hashLock].expected;
        emit AssetEscrowed(
            msg.sender,
            assets[hashLock].expected,
            msg.sender,
            address(this),
            premiums[hashLock].expected,
            assets[hashLock].current
        );
    }

    /**
    redeemAsset redeems the asset for the new owner
    */
    function redeemAsset(bytes32 preimage, bytes32 hashLock) 
        public 
        canRedeemAsset(preimage, hashLock) 
    {
        //TODO
        ERC20(swaps[hashLock].assetAddress).transfer(msg.sender, assets[hashLock].current);
        // update the current asset
        assets[hashLock].current = 0;
        // emit the event
        emit AssetRedeemed(
            msg.sender,
            assets[hashLock].expected,
            address(this),
            msg.sender,
            premiums[hashLock].current,
            assets[hashLock].current
        );
    }

    /**
    refundPremium refunds the premiumEscrower's premium should the swap succeed
    */
    function refundPremium(bytes32 hashLock) 
        public 
        canRefundPremium(hashLock)
    {
        //TODO
        // transfer the premium to the premium escrower
        ERC20(swaps[hashLock].assetAddress).transfer(swaps[hashLock].premiumEscrower, premiums[hashLock].current);
        // swaps[hashLock].premiumEscrower.transfer(premiums[hashLock].current);
        // update the current premium
        premiums[hashLock].current = 0;
        // emit the event
        emit PremiumRefunded(
            msg.sender,
            premiums[hashLock].expected,
            address(this),
            swaps[hashLock].premiumEscrower,
            premiums[hashLock].current,
            assets[hashLock].current
        );
    }

    /**
    refundAsset refunds the asset to its original owner should the swap fail
    */
    function refundAsset(bytes32 hashLock) 
        public 
        canRefundAsset(hashLock) 
    {
       //TODO
        ERC20(swaps[hashLock].assetAddress).transfer(swaps[hashLock].assetEscrower, assets[hashLock].current);
        // swaps[hashLock].assetEscrower.transfer(assets[hashLock].current);
        assets[hashLock].current = 0;
        emit AssetRefunded(
            msg.sender,
            assets[hashLock].expected,
            address(this),
            swaps[hashLock].assetEscrower,
            premiums[hashLock].current,
            assets[hashLock].current
        );
    }

    /**
    redeemPremium allows a party to redeem the counterparty's premium should the swap fail
    */
    function redeemPremium(bytes32 hashLock) 
        public 
        canRedeemPremium(hashLock)
    {
        //TODO
        ERC20(swaps[hashLock].assetAddress).transfer(msg.sender, premiums[hashLock].current);
        premiums[hashLock].current -= premiums[hashLock].expected;
        emit PremiumRedeemed(
            msg.sender,
            premiums[hashLock].expected,
            address(this),
            swaps[hashLock].premiumEscrower,
            premiums[hashLock].current,
            assets[hashLock].current
        );
    }
}
