using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace TokenBar.Services
{
    /// <summary>
    /// 阿里云 OpenAPI V3 签名（ACS3-HMAC-SHA256）。
    ///
    /// 与官方百炼 CLI (bailian-cli-core) 内部的 Pt() 实现逐行对齐，供以下接口复用：
    /// - GenerateCLIAccessToken：用长期 AccessKey 换控制台 access_token，
    ///   不经过浏览器、不受控制台单点登录 (SSO) 多设备互踢限制；
    /// - QueryAccountBalance：查询阿里云账户现金余额。
    ///
    /// 本文件须与 mac 端 AliyunSigner.swift 保持逐行一致。Windows 端没有测试工程，
    /// 因此把 mac 端 testAliyunSignerGoldenVector 的黄金向量钉在这里，改动后请手工比对：
    ///
    ///   host      = modelstudio.cn-beijing.aliyuncs.com
    ///   pathname  = /modelstudio/cli/generateAccessToken
    ///   method    = POST，query 为空，body 为空
    ///   action    = GenerateCLIAccessToken，version = 2026-02-10
    ///   AK/SK     = LTAItestAK / testSecret
    ///   date      = 2024-01-01T00:00:00Z
    ///   nonce     = 00000000-0000-4000-8000-000000000000
    /// 期望：
    ///   SignedHeaders   = content-type;host;x-acs-action;x-acs-content-sha256;
    ///                     x-acs-date;x-acs-signature-nonce;x-acs-version
    ///   sha256(CR)      = e0075df56bc9c8d65e87022d8e6a1dd873f6b2a603636e5ec63bdacbbb630cbd
    ///   Signature       = 0efe27d7d7a62efb7c47fb992c4ea0955cfc16a1031c1a93c4edb896e859c4c4
    ///
    /// 两个必踩的坑：
    /// 1. header / query 排序必须用 StringComparer.Ordinal —— 默认比较器是文化敏感的，会排错序；
    /// 2. content-type 恒为 "application/json" 且参与签名，即使 body 为空。发送时必须写成
    ///    req.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
    ///    直接 new StringContent(s, Encoding.UTF8, "application/json") 会发出
    ///    "application/json; charset=utf-8"，与签名不一致，服务端必返 SignatureDoesNotMatch。
    /// </summary>
    public static class AliyunSigner
    {
        public const string Algorithm = "ACS3-HMAC-SHA256";

        /// <summary>空 body 的 SHA256，GenerateCLIAccessToken 这类无参接口会用到。</summary>
        public const string EmptyBodySha256 =
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

        // ---------- 对外入口 ----------

        /// <summary>生成签好名的请求头（含 authorization）。</summary>
        /// <param name="host">接口域名，不带协议，例如 modelstudio.cn-beijing.aliyuncs.com</param>
        /// <param name="pathname">请求路径，RPC 风格接口固定为 "/"</param>
        /// <param name="queryString">已规范化的 canonical query string（用 CanonicalQueryString 生成），无参数传空串</param>
        /// <param name="body">请求体，无 body 传 null 或空数组</param>
        /// <param name="date">仅供测试注入固定值，业务调用传 null</param>
        /// <param name="nonce">仅供测试注入固定值，业务调用传 null</param>
        public static Dictionary<string, string> SignedHeaders(
            string host,
            string action,
            string version,
            string accessKeyId,
            string accessKeySecret,
            string pathname = "/",
            string method = "POST",
            string queryString = "",
            byte[]? body = null,
            string? securityToken = null,
            DateTime? date = null,
            string? nonce = null)
        {
            var contentSha256 = HexSha256(body ?? Array.Empty<byte>());
            var headers = CanonicalHeaderMap(
                host, action, version,
                date ?? DateTime.UtcNow,
                nonce ?? Guid.NewGuid().ToString(),
                contentSha256,
                securityToken);

            var signedHeaderList = SignedHeaderList(headers);
            var canonicalRequest = CanonicalRequest(method, pathname, queryString, headers, contentSha256);
            var signature = HexHmacSha256(accessKeySecret, StringToSign(canonicalRequest));

            headers["authorization"] =
                $"{Algorithm} Credential={accessKeyId},SignedHeaders={signedHeaderList},Signature={signature}";
            return headers;
        }

        // ---------- 中间产物（单独暴露便于手工比对） ----------

        /// <summary>参与签名的 header 固定集合：host、content-type 与全部 x-acs-*。</summary>
        internal static Dictionary<string, string> CanonicalHeaderMap(
            string host,
            string action,
            string version,
            DateTime date,
            string nonce,
            string contentSha256,
            string? securityToken)
        {
            var headers = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["host"] = host,
                ["content-type"] = "application/json",
                ["x-acs-action"] = action,
                ["x-acs-version"] = version,
                ["x-acs-date"] = Iso8601Seconds(date),
                ["x-acs-signature-nonce"] = nonce,
                ["x-acs-content-sha256"] = contentSha256
            };
            if (!string.IsNullOrEmpty(securityToken))
            {
                headers["x-acs-security-token"] = securityToken!;
            }
            return headers;
        }

        /// <summary>按 key 升序拼成 a;b;c。</summary>
        internal static string SignedHeaderList(IReadOnlyDictionary<string, string> headerMap)
            => string.Join(";", SignedKeys(headerMap));

        internal static string CanonicalRequest(
            string method,
            string pathname,
            string queryString,
            IReadOnlyDictionary<string, string> headerMap,
            string contentSha256)
        {
            var keys = SignedKeys(headerMap);
            // 每行一个 header，整体以换行结尾 —— 于是 canonicalRequest 中会出现一个空行
            var canonicalHeaders = string.Concat(keys.Select(k => $"{k}:{headerMap[k]}\n"));
            return string.Join("\n",
                method,
                pathname,
                queryString,
                canonicalHeaders,
                string.Join(";", keys),
                contentSha256);
        }

        internal static string StringToSign(string canonicalRequest)
            => Algorithm + "\n" + HexSha256(Encoding.UTF8.GetBytes(canonicalRequest));

        private static List<string> SignedKeys(IReadOnlyDictionary<string, string> headerMap)
            => headerMap.Keys
                .Where(k => k == "host" || k == "content-type" || k.StartsWith("x-acs-", StringComparison.Ordinal))
                .OrderBy(k => k, StringComparer.Ordinal)
                .ToList();

        // ---------- 编码与摘要 ----------

        /// <summary>
        /// 把查询参数拼成 canonical query string：key 升序、键值均按 RFC3986 编码、空值参数丢弃。
        /// </summary>
        public static string CanonicalQueryString(IReadOnlyDictionary<string, string> parameters)
            => string.Join("&", parameters
                .Where(kv => !string.IsNullOrEmpty(kv.Value))
                .OrderBy(kv => kv.Key, StringComparer.Ordinal)
                .Select(kv => $"{PercentEncode(kv.Key)}={PercentEncode(kv.Value)}"));

        /// <summary>
        /// RFC3986 编码：只保留 A-Z a-z 0-9 - _ . ~，其余按 UTF-8 逐字节转义为大写 %XX。
        /// 刻意不用 Uri.EscapeDataString —— 其保留字符集在不同 .NET 版本上变化过，
        /// 而签名对编码结果逐字节敏感，这里手写以保证与 mac 端行为完全一致。
        /// </summary>
        public static string PercentEncode(string value)
        {
            var sb = new StringBuilder(value.Length * 3);
            foreach (var b in Encoding.UTF8.GetBytes(value))
            {
                var c = (char)b;
                if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
                    || c == '-' || c == '_' || c == '.' || c == '~')
                {
                    sb.Append(c);
                }
                else
                {
                    sb.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
                }
            }
            return sb.ToString();
        }

        /// <summary>
        /// x-acs-date 要求 ISO8601 秒精度并以 Z 结尾，例如 2024-01-01T00:00:00Z。
        /// 必须固定 InvariantCulture + UTC，否则在非公历 locale 下会产出非 ISO 文本导致签名失败。
        /// </summary>
        internal static string Iso8601Seconds(DateTime date)
            => date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

        public static string HexSha256(byte[] data)
            => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

        public static string HexHmacSha256(string key, string message)
            => Convert.ToHexString(
                HMACSHA256.HashData(Encoding.UTF8.GetBytes(key), Encoding.UTF8.GetBytes(message)))
               .ToLowerInvariant();
    }
}
