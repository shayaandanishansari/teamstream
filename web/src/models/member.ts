import type { RecordModel } from "pocketbase";
import { readStr } from "./wire";

/** Port of app/lib/models/member.dart. */
export interface Member {
  id: string;
  name: string;
  /** Hex, e.g. "#00A896". Editable in the admin UI, which is exactly why
   *  tokens.css never puts text on it and never uses it as text. */
  color: string;
}

/* The Dart defaults an absent colour to '#00A896' — which is Shayaan's. A
 * member with no colour therefore rendered AS him. Empty here, and the UI
 * renders unknown members in ink. */
export const toMember = (r: RecordModel): Member => ({
  id: r.id,
  name: readStr(r.name),
  color: readStr(r.color),
});
