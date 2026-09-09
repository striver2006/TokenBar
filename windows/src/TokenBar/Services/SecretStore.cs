using System;
using System.Runtime.InteropServices;
using System.Text;

namespace TokenBar.Services
{
    /// <summary>钥匙串 / 凭据管理器条目名。与 mac 端 SecretKey 的 rawValue 同名。</summary>
    public enum SecretKey
    {
        AliyunAccessKeySecret,
        AliyunConsoleAccessToken
    }

    /// <summary>
    /// 高敏凭证的存取抽象。目前只托管阿里云 AccessKey Secret 与控制台 access_token ——
    /// 其余厂商的 API Key 维持原有的 settings.json 明文存储不变。
    ///
    /// AccessKey Secret 是阿里云账号级长期凭证，落到 %AppData%\TokenBar\settings.json
    /// 里等于任何以该用户身份运行的进程都能明文读走，所以单独走 Windows 凭据管理器。
    ///
    /// 选凭据管理器而不是 System.Security.Cryptography.ProtectedData（DPAPI）：后者在
    /// .NET 8 是独立 NuGet 包，要动 csproj；而 GeminiService 已经 P/Invoke 了 CredReadW，
    /// 加上 CredWriteW / CredDeleteW 零新依赖、风格一致，且凭据管理器本身就受 DPAPI 保护。
    ///
    /// 本文件须与 mac 端 SecretStore.swift 保持行为一致。
    /// </summary>
    public interface ISecretStore
    {
        /// <summary>写入成功返回 true。凭据管理器不可用时返回 false，由调用方决定是否退回明文。</summary>
        bool Set(SecretKey key, string value);
        string? Get(SecretKey key);
        bool Delete(SecretKey key);
    }

    public sealed class CredentialSecretStore : ISecretStore
    {
        public static CredentialSecretStore Instance { get; } = new CredentialSecretStore();

        private const int CRED_TYPE_GENERIC = 1;
        private const int CRED_PERSIST_LOCAL_MACHINE = 2;

        private readonly string _prefix;

        public CredentialSecretStore(string prefix = "TokenBar/")
        {
            _prefix = prefix;
        }

        private string TargetName(SecretKey key) => _prefix + key;

        // ---------- P/Invoke ----------

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredRead(string target, int type, int reservedFlag, out IntPtr credentialPtr);

        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredWrite(ref CREDENTIAL credential, int flags);

        [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredDelete(string target, int type, int reservedFlag);

        [DllImport("advapi32.dll", EntryPoint = "CredFree", SetLastError = true)]
        private static extern void CredFree(IntPtr cred);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL
        {
            public int Flags;
            public int Type;
            public string TargetName;
            public string? Comment;
            public long LastWritten;
            public int CredentialBlobSize;
            public IntPtr CredentialBlob;
            public int Persist;
            public int AttributeCount;
            public IntPtr Attributes;
            public string? TargetAlias;
            public string UserName;
        }

        // ---------- ISecretStore ----------

        public bool Set(SecretKey key, string value)
        {
            var blob = IntPtr.Zero;
            try
            {
                var bytes = Encoding.UTF8.GetBytes(value ?? string.Empty);
                blob = Marshal.AllocHGlobal(bytes.Length);
                Marshal.Copy(bytes, 0, blob, bytes.Length);

                var cred = new CREDENTIAL
                {
                    Flags = 0,
                    Type = CRED_TYPE_GENERIC,
                    TargetName = TargetName(key),
                    Comment = "TokenBar 托管的阿里云凭证",
                    CredentialBlobSize = bytes.Length,
                    CredentialBlob = blob,
                    Persist = CRED_PERSIST_LOCAL_MACHINE,
                    AttributeCount = 0,
                    Attributes = IntPtr.Zero,
                    UserName = "TokenBar"
                };
                return CredWrite(ref cred, 0);
            }
            catch
            {
                return false;
            }
            finally
            {
                if (blob != IntPtr.Zero) Marshal.FreeHGlobal(blob);
            }
        }

        public string? Get(SecretKey key)
        {
            try
            {
                if (!CredRead(TargetName(key), CRED_TYPE_GENERIC, 0, out var ptr)) return null;
                try
                {
                    var cred = Marshal.PtrToStructure<CREDENTIAL>(ptr);
                    if (cred.CredentialBlobSize <= 0 || cred.CredentialBlob == IntPtr.Zero) return null;

                    var bytes = new byte[cred.CredentialBlobSize];
                    Marshal.Copy(cred.CredentialBlob, bytes, 0, cred.CredentialBlobSize);
                    var value = Encoding.UTF8.GetString(bytes);
                    return string.IsNullOrEmpty(value) ? null : value;
                }
                finally
                {
                    CredFree(ptr);
                }
            }
            catch
            {
                return null;
            }
        }

        public bool Delete(SecretKey key)
        {
            try
            {
                // 条目本来就不存在时 CredDelete 返回 false，语义上等同删除成功
                return CredDelete(TargetName(key), CRED_TYPE_GENERIC, 0) || Get(key) == null;
            }
            catch
            {
                return false;
            }
        }
    }
}
