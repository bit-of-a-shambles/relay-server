export type ApnsJwtSecrets = {
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
};

export type JwtFactory = (secrets: ApnsJwtSecrets, issuedAtSeconds: number) => Promise<string>;

export const JWT_REFRESH_SECONDS = 50 * 60;

function base64UrlEncode(value: Uint8Array): string {
  let binary = "";
  for (const byte of value) {
    binary += String.fromCharCode(byte);
  }

  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function jsonBase64UrlEncode(value: object): string {
  return base64UrlEncode(new TextEncoder().encode(JSON.stringify(value)));
}

function pemToPkcs8(pem: string): ArrayBuffer {
  const encoded = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");
  const decoded = atob(encoded);
  const bytes = new Uint8Array(decoded.length);

  for (let index = 0; index < decoded.length; index += 1) {
    bytes[index] = decoded.charCodeAt(index);
  }

  return bytes.buffer;
}

export async function createApnsJwt(
  secrets: ApnsJwtSecrets,
  issuedAtSeconds: number
): Promise<string> {
  const header = { alg: "ES256", kid: secrets.APNS_KEY_ID };
  const claims = { iss: secrets.APNS_TEAM_ID, iat: issuedAtSeconds };
  const encodedHeader = jsonBase64UrlEncode(header);
  const encodedClaims = jsonBase64UrlEncode(claims);
  const signingInput = `${encodedHeader}.${encodedClaims}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8(secrets.APNS_KEY_P8),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput)
  );

  return `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`;
}

export class ApnsJwtCache {
  private cached: { token: string; refreshAt: number } | null = null;
  private pending: Promise<string> | null = null;

  public constructor(
    private readonly jwtFactory: JwtFactory = createApnsJwt,
    private readonly refreshSeconds = JWT_REFRESH_SECONDS
  ) {}

  public get(secrets: ApnsJwtSecrets, nowSeconds: number): Promise<string> {
    if (this.cached !== null && nowSeconds < this.cached.refreshAt) {
      return Promise.resolve(this.cached.token);
    }
    if (this.pending !== null) {
      return this.pending;
    }

    const pending = this.jwtFactory(secrets, nowSeconds).then(
      (token) => {
        this.cached = { token, refreshAt: nowSeconds + this.refreshSeconds };
        this.pending = null;
        return token;
      },
      (error: unknown) => {
        this.pending = null;
        throw error;
      }
    );
    this.pending = pending;
    return pending;
  }
}
