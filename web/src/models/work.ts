import type { RecordModel } from "pocketbase";
import { readBool, readNum, readStr } from "./wire";

/** Port of app/lib/models/work.dart. */
export interface Work {
  id: string;
  title: string;
  /** Creation timestamp in millis, used only as a tie-break sort key.
   *  Written once at create and never updated — there is no reorder anywhere
   *  in this app, in either the Dart or here. */
  position: number;
  archived: boolean;
}

export const toWork = (r: RecordModel): Work => ({
  id: r.id,
  title: readStr(r.title),
  position: readNum(r.position),
  archived: readBool(r.archived),
});
