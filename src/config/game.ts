export type Mode = 'quick' | 'time' | 'practice';
export type Quality = 'low' | 'medium' | 'high';
export type ItemKind = 'battery' | 'peel' | 'gear' | 'firefly';
export const ITEMS: Record<ItemKind, {name:string; icon:string; color:number}> = {
  battery:{name:'涡轮电池',icon:'ϟ',color:0xa9ff79}, peel:{name:'弹跳果皮',icon:'✿',color:0xffb95e},
  gear:{name:'回旋齿轮',icon:'⚙',color:0x8be7ff},firefly:{name:'追踪萤火弹',icon:'✦',color:0xff7bb2}
};
export const KARTS = [
  {id:'pip', name:'皮普', title:'苔帽邮差', vehicle:'薄荷邮驹', type:'均衡型', color:0x79edbe, accent:0xfef1b5, speed:29, accel:19, turn:1.85, mass:105, drift:1, stats:[4,4,4], lore:'把每一封信，送到风的前面。'},
  {id:'lumi', name:'露米', title:'星灯学徒', vehicle:'蜜桃流星', type:'轻量型', color:0xff8fb4, accent:0xa0e4ff, speed:27, accel:23, turn:2.05, mass:82, drift:1, stats:[3,5,5], lore:'小小车身，也能装下一整片星空。'},
  {id:'brass', name:'布拉斯', title:'钟楼铸匠', vehicle:'黄铜甲虫', type:'重量型', color:0xffbf55, accent:0x546d8f, speed:32, accel:16, turn:1.60, mass:145, drift:0.9, stats:[5,3,3], lore:'齿轮转起来，整座山谷都听得见。'},
  {id:'wisp', name:'维斯', title:'夜风织匠', vehicle:'紫雾燕尾', type:'漂移型', color:0xb29bff, accent:0xd6ffb4, speed:28, accel:20, turn:1.95, mass:95, drift:1.3, stats:[4,4,5], lore:'在弯道上，缝一条发光的线。'}
] as const;
export type KartSpec = typeof KARTS[number];
export const TRACK_NAME = '发条蘑菇山谷';
export const LAPS = 3;
export const CHECKPOINTS = 16;
export const CUP_POINTS = [12,9,7,5,4,3,2,1];
export const CUPS = [
  {id:'sprout',name:'萌芽杯',tracks:['发条蘑菇山谷','茶壶温室','风铃树梢','苔藓驿站']},
  {id:'tide',name:'潮汐杯',tracks:['贝壳港湾','珊瑚钟塔','漂流瓶湾','月潮堤岸']},
  {id:'ember',name:'余烬杯',tracks:['琥珀熔炉','焦糖矿井','蒸汽峡谷','红铜高原']},
  {id:'star',name:'星绒杯',tracks:['云织工坊','极光花园','浮岛图书馆','流星王庭']}
];
export const QUALITY = {
  low:{pixelRatio:1,shadow:0,particles:45,scenery:0.55},
  medium:{pixelRatio:1.5,shadow:1024,particles:100,scenery:0.8},
  high:{pixelRatio:2,shadow:2048,particles:180,scenery:1}
};
