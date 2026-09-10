using System;
using TokenBar.Services;
using Xunit;

namespace TokenBar.Tests
{
    /// <summary>
    /// 黄金向量与 mac 端 TokenBarTests.testAliyunSignerGoldenVector 完全一致；
    /// 任一端改了签名实现，两边测试必须同时通过。
    /// </summary>
    public class AliyunSignerTests
    {
        private static readonly DateTime FixedDate = new DateTime(2024, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        private const string FixedNonce = "00000000-0000-4000-8000-000000000000";
        private const string Host = "modelstudio.cn-beijing.aliyuncs.com";
        private const string Pathname = "/modelstudio/cli/generateAccessToken";

        [Fact]
        public void GoldenVector_MatchesMacImplementation()
        {
            var headers = AliyunSigner.SignedHeaders(
                host: Host,
                action: "GenerateCLIAccessToken",
                version: "2026-02-10",
                accessKeyId: "LTAItestAK",
                accessKeySecret: "testSecret",
                pathname: Pathname,
                date: FixedDate,
                nonce: FixedNonce);

            Assert.Equal("2024-01-01T00:00:00Z", headers["x-acs-date"]);
            Assert.Equal("application/json", headers["content-type"]);
            Assert.Equal(AliyunSigner.EmptyBodySha256, headers["x-acs-content-sha256"]);
            Assert.False(headers.ContainsKey("x-acs-security-token"));

            const string expectedSignedHeaders =
                "content-type;host;x-acs-action;x-acs-content-sha256;x-acs-date;x-acs-signature-nonce;x-acs-version";
            const string expectedSignature = "0efe27d7d7a62efb7c47fb992c4ea0955cfc16a1031c1a93c4edb896e859c4c4";
            Assert.Equal(
                $"ACS3-HMAC-SHA256 Credential=LTAItestAK,SignedHeaders={expectedSignedHeaders},Signature={expectedSignature}",
                headers["authorization"]);
        }

        [Fact]
        public void GoldenVector_CanonicalRequestHash()
        {
            var headerMap = AliyunSigner.CanonicalHeaderMap(
                Host, "GenerateCLIAccessToken", "2026-02-10", FixedDate, FixedNonce,
                AliyunSigner.EmptyBodySha256, securityToken: null);
            var canonical = AliyunSigner.CanonicalRequest("POST", Pathname, "", headerMap, AliyunSigner.EmptyBodySha256);

            Assert.Equal(
                "e0075df56bc9c8d65e87022d8e6a1dd873f6b2a603636e5ec63bdacbbb630cbd",
                AliyunSigner.HexSha256(System.Text.Encoding.UTF8.GetBytes(canonical)));
            Assert.Equal(
                "ACS3-HMAC-SHA256\ne0075df56bc9c8d65e87022d8e6a1dd873f6b2a603636e5ec63bdacbbb630cbd",
                AliyunSigner.StringToSign(canonical));
        }

        [Fact]
        public void EmptyBodyHash_IsSha256OfNothing()
        {
            Assert.Equal(AliyunSigner.EmptyBodySha256, AliyunSigner.HexSha256(Array.Empty<byte>()));
        }

        [Fact]
        public void PercentEncode_FollowsRfc3986()
        {
            Assert.Equal("a-b_c.d~e", AliyunSigner.PercentEncode("a-b_c.d~e"));
            Assert.Equal("%20", AliyunSigner.PercentEncode(" "));
            Assert.Equal("%2F", AliyunSigner.PercentEncode("/"));
            Assert.Equal("%E4%B8%AD", AliyunSigner.PercentEncode("中"));
        }

        [Fact]
        public void SecurityToken_IsIncludedWhenPresent()
        {
            var headers = AliyunSigner.SignedHeaders(
                Host, "GenerateCLIAccessToken", "2026-02-10", "ak", "sk", Pathname,
                securityToken: "sts-token", date: FixedDate, nonce: FixedNonce);
            Assert.Equal("sts-token", headers["x-acs-security-token"]);
            Assert.Contains("x-acs-security-token", headers["authorization"]);
        }
    }
}
