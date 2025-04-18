import * as fs from "fs";
import * as snarkjs from "snarkjs";
import paillierBigint from "paillier-bigint";

import { getRandomBigInt } from "../common/common";
import { ZkTips } from "../../typechain-types";
import { MiMC } from "../common/MiMC";

export async function transfer(
  zkTips: ZkTips,
  signer: any,
  senderKeys: paillierBigint.KeyPair,
  receiverKeys: paillierBigint.KeyPair,
  value: bigint,
  authSecret: string,
  idFrom: bigint,
  idTo: bigint
) {
  const mimcSponge = new MiMC();
  await mimcSponge.init();

  const authCommitment = mimcSponge.simpleHash(authSecret);

  const { proof, publicSignals } = await transferProof(
    senderKeys,
    receiverKeys,
    value,
    await zkTips.balanceOf(idFrom),
    BigInt(authCommitment),
    BigInt(authSecret)
  );

  await zkTips.connect(signer).transfer(
    idFrom,
    idTo,
    [proof.pi_a[0], proof.pi_a[1]],
    [
      [proof.pi_b[0][1], proof.pi_b[0][0]],
      [proof.pi_b[1][1], proof.pi_b[1][0]],
    ],
    [proof.pi_c[0], proof.pi_c[1]],
    [publicSignals[0], publicSignals[1], publicSignals[2], publicSignals[3]]
  );
}

export async function transferAgregation(
  senderKeys: paillierBigint.KeyPair,
  receiverKeys: paillierBigint.KeyPair,
  value: bigint,
  authSecret: string,
  index: bigint,
  balance: bigint
) {
  const mimcSponge = new MiMC();
  await mimcSponge.init();

  const authCommitment = mimcSponge.simpleHash(authSecret);

  const { proof, publicSignals } = await transferProof(
    senderKeys,
    receiverKeys,
    value,
    balance,
    BigInt(authCommitment),
    BigInt(authSecret)
  );

  // Save proof and public signals to files
  fs.writeFileSync(
    `test/transfer/transferAgregation/proof_${index}.json`,
    JSON.stringify(proof)
  );
  fs.writeFileSync(
    `test/transfer/transferAgregation/public_signals_${index}.json`,
    JSON.stringify(publicSignals)
  );

  return senderKeys.publicKey.addition(balance, BigInt(publicSignals[1]));
}

export async function transferProof(
  senderKeys: paillierBigint.KeyPair,
  receiverKeys: paillierBigint.KeyPair,
  value: bigint,
  encryptedSenderBalance: bigint,
  authCommitment: bigint,
  authSecret: bigint
) {
  return await snarkjs.groth16.fullProve(
    getTransferData(
      senderKeys,
      receiverKeys,
      value,
      encryptedSenderBalance,
      authCommitment,
      authSecret
    ),
    "test/transfer/transfer.wasm",
    "test/transfer/transfer.zkey"
  );
}

export async function verifyTransferProof(
  proof: snarkjs.Groth16Proof,
  publicSignals: snarkjs.PublicSignals
) {
  const vKey = JSON.parse(
    fs.readFileSync("test/transfer/verification_key.json", "utf-8")
  );

  return await snarkjs.groth16.verify(vKey, publicSignals, proof);
}

export function getTransferData(
  senderKeys: paillierBigint.KeyPair,
  receiverKeys: paillierBigint.KeyPair,
  value: bigint,
  encryptedSenderBalance: bigint,
  authCommitment: bigint,
  authSecret: bigint
) {
  const sender_rand_r = getRandomBigInt(senderKeys.publicKey.n);
  const receiver_rand_r = getRandomBigInt(receiverKeys.publicKey.n);
  const encryptedSenderValue = senderKeys.publicKey.encrypt(
    senderKeys.publicKey.n - value,
    sender_rand_r
  );
  const encryptedReceiverValue = receiverKeys.publicKey.encrypt(
    value,
    receiver_rand_r
  );
  const senderPubKey = [
    senderKeys.publicKey.g,
    sender_rand_r,
    senderKeys.publicKey.n,
  ];
  const receiverPubKey = [
    receiverKeys.publicKey.g,
    receiver_rand_r,
    receiverKeys.publicKey.n,
  ];
  const senderPrivKey = [
    senderKeys.privateKey.lambda,
    senderKeys.privateKey.mu,
    senderKeys.privateKey.n,
  ];

  return {
    encryptedSenderBalance,
    encryptedSenderValue,
    encryptedReceiverValue,
    value,
    authCommitment,
    authSecret,
    senderPubKey,
    receiverPubKey,
    senderPrivKey,
  };
}
