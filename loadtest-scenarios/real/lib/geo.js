// V2 성장 가정의 수도권 업무지구 6개 거점. 시드 데이터와 조회 부하가 같은 좌표계를 쓰도록 한 곳에서 관리한다.
import { envFloat } from './env.js';

export const DISTRICTS = [
  { key: 'pangyo', name: '판교역', lat: 37.394726, lng: 127.111209 },
  { key: 'gangnam', name: '강남역', lat: 37.497952, lng: 127.027619 },
  { key: 'yeouido', name: '여의도역', lat: 37.521624, lng: 126.924191 },
  { key: 'gwanghwamun', name: '광화문역', lat: 37.571026, lng: 126.976669 },
  { key: 'seongsu', name: '성수역', lat: 37.544581, lng: 127.055961 },
  { key: 'gasan', name: '가산디지털단지역', lat: 37.481072, lng: 126.882343 },
];

// 모바일 지도 한 화면(줌 15~16) 수준. map-pins는 서버에서 뷰포트 크기를 검증하지 않으므로
// 너무 넓은 뷰포트는 현실과 다른 풀스캔 부하가 된다.
const LAT_SPAN = envFloat('VIEWPORT_LAT_SPAN', 0.02, 0.001, 1);
const LNG_SPAN = envFloat('VIEWPORT_LNG_SPAN', 0.025, 0.001, 1);
const JITTER = envFloat('POINT_JITTER', 0.008, 0, 0.5);

function round6(value) {
  return Math.round(value * 1e6) / 1e6;
}

// 결정적 의사난수 (같은 seed → 같은 좌표). 시드와 재검색 패턴을 재현하기 위함.
export function rand(seed) {
  const x = Math.sin(seed * 9301 + 49297) * 233280;
  return x - Math.floor(x);
}

export function district(index) {
  return DISTRICTS[((index % DISTRICTS.length) + DISTRICTS.length) % DISTRICTS.length];
}

export function pointNear(d, seed, jitter = JITTER) {
  return {
    lat: round6(d.lat + (rand(seed) - 0.5) * 2 * jitter),
    lng: round6(d.lng + (rand(seed + 7) - 0.5) * 2 * jitter),
  };
}

export function viewportAround(center, scale = 1) {
  const halfLat = (LAT_SPAN * scale) / 2;
  const halfLng = (LNG_SPAN * scale) / 2;
  return {
    sw_lat: round6(center.lat - halfLat),
    sw_lng: round6(center.lng - halfLng),
    ne_lat: round6(center.lat + halfLat),
    ne_lng: round6(center.lng + halfLng),
  };
}

// 서버는 Asia/Seoul LocalDateTime을 쓰고 오프셋 포함 문자열도 받는다(OffsetAwareLocalDateTimeDeserializer).
export function kstIso(date) {
  const kst = new Date(date.getTime() + 9 * 3600 * 1000);
  return `${kst.toISOString().slice(0, 19)}+09:00`;
}

export function minutesFromNow(minutes) {
  return kstIso(new Date(Date.now() + minutes * 60 * 1000));
}

// 택시팟은 출발시각을 분 단위로 정규화해 "완전 일치"로 매칭한다.
export function taxiDepartureMinute(offsetMinutes) {
  const t = new Date(Date.now() + offsetMinutes * 60 * 1000);
  t.setUTCSeconds(0, 0);
  return kstIso(t);
}
