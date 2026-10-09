import { ethers } from "hardhat";
import { ethers as rawEthers } from "ethers";
import { getContracts } from "../lib/artifacts";

const ALICE = "0x00000000000000000000000000000000000A11CE";
const RPC = process.env.ANVIL_RPC || "http://127.0.0.1:8545";

async function main() {
  const [deployer] = await ethers.getSigners();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  const { contracts } = getContracts(deployer, chainId);
  const { CombatEngine: ce } = contracts;

  await ethers.provider.send("anvil_impersonateAccount", [ALICE]);
  await ethers.provider.send("anvil_setBalance", [ALICE, "0x56BC75E2D63100000"]);
  const rawProvider = new rawEthers.JsonRpcProvider(RPC);
  const alice = await rawProvider.getSigner(ALICE);

  const rc0 = await (await ce.createRoom(1)).wait();
  const ev0 = rc0.logs.map((l: any) => { try { return ce.interface.parseLog(l); } catch { return null; } }).find((e: any) => e && e.name === "RoomCreated");
  const roomId = Number(ev0.args.roomId);
  console.log(`Room ${roomId} created`);

  await (await ce.connect(alice).joinRoom(roomId, 1)).wait();
  const plan = new Array(16).fill(0);
  plan[0] = 1;
  await (await ce.connect(alice).setPlan(roomId, plan, 1)).wait();
  await (await ce.startCombat(roomId)).wait();
  console.log("combat started");

  for (let i = 0; i < 8; i++) {
    await (await ce.advanceTurn(roomId, { gasLimit: 2_000_000 })).wait();
    const r = await ce.getRoom(roomId);
    const m0 = r.members[0];
    const e0 = r.enemies[0];
    const e1 = r.enemies[1];
    console.log(`turn=${Number(r.turnId)} phase=${Number(r.phase)} | alice hp=${m0.hp} ap=${m0.ap} | slime0 hp=${e0.hp} slime1 hp=${e1.hp}`);
  }
}
main().catch((e) => { console.error(e); process.exitCode = 1; });
