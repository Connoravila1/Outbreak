export interface LatLon { lat: number; lon: number }
export interface Fix extends LatLon { acc: number; t: number }

const R = 6371008.8;
const rad = (d: number) => (d * Math.PI) / 180;

/** Great-circle distance in metres. */
export function haversine(a: LatLon, b: LatLon): number {
  const dLat = rad(b.lat - a.lat);
  const dLon = rad(b.lon - a.lon);
  const s = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(s)));
}

/** Move `p` by metres north / east (flat-earth, fine under a few km). */
export function offset(p: LatLon, northM: number, eastM: number): LatLon {
  return {
    lat: p.lat + (northM / R) * (180 / Math.PI),
    lon: p.lon + (eastM / (R * Math.cos(rad(p.lat)))) * (180 / Math.PI),
  };
}

export function formatDistance(m: number): string {
  return m < 1000 ? `${Math.round(m)} m` : `${(m / 1000).toFixed(1)} km`;
}
