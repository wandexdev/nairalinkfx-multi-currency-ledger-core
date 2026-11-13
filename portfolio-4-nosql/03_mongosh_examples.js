// Portfolio 4 - the same ideas in native mongosh syntax.  Run:  mongosh "mongodb://127.0.0.1:27017/?replicaSet=rs0" --quiet 03_mongosh_examples.js
const db = db.getSiblingDB("nairalink_nosql");
print("--- CRUD: one customer profile (embedded KYC documents + devices)");
printjson(db.customer_profiles.findOne({_id: 4}, {full_name: 1, "kyc.tier": 1, "kyc.documents.type": 1, "kyc.documents.status": 1}));
print("--- Query: tier-2+ customers with a REJECTED document  (count)");
print(db.customer_profiles.countDocuments({"kyc.tier": {$gte: 2}, "kyc.documents": {$elemMatch: {status: "REJECTED"}}}));
print("--- Aggregation: FX volume by currency, October 2026");
db.trade_events.aggregate([{$match: {type: "FX_CONVERSION", month: "2026-10"}},
  {$group: {_id: "$details.buy_ccy", orders: {$sum: 1}, ngn: {$sum: "$details.sell_amount"}}}, {$sort: {_id: 1}}]).forEach(printjson);
print("--- Explain: history query uses the compound index");
const ex = db.trade_events.find({customer_id: 777}).sort({ts: -1}).limit(20).explain("executionStats");
print("stage:", JSON.stringify(ex.queryPlanner.winningPlan.inputStage ? ex.queryPlanner.winningPlan.inputStage.stage : ex.queryPlanner.winningPlan.stage),
      "| keysExamined:", ex.executionStats.totalKeysExamined, "| docsExamined:", ex.executionStats.totalDocsExamined);
print("--- Replica set status");
printjson(db.getMongo().getDB("admin").runCommand({replSetGetStatus: 1}).members.map(m => ({name: m.name, state: m.stateStr})));
