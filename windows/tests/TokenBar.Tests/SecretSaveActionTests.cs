using TokenBar.Services;
using Xunit;

namespace TokenBar.Tests
{
    public class SecretSaveActionTests
    {
        [Theory]
        [InlineData("secret", true)]
        [InlineData("secret", false)]
        [InlineData("  padded  ", true)]
        public void NonEmptyInput_AlwaysWrites(string input, bool storeReadable)
        {
            var action = SecretSaveAction.Resolve(input, storeReadable);
            Assert.Equal(SecretSaveActionKind.Write, action.Kind);
            Assert.Equal(input.Trim(), action.Value);
        }

        [Theory]
        [InlineData("")]
        [InlineData("   ")]
        [InlineData(null)]
        public void EmptyInput_WithReadableStore_Deletes(string? input)
        {
            var action = SecretSaveAction.Resolve(input, storeReadable: true);
            Assert.Equal(SecretSaveActionKind.Delete, action.Kind);
            Assert.Null(action.Value);
        }

        [Theory]
        [InlineData("")]
        [InlineData("   ")]
        [InlineData(null)]
        public void EmptyInput_WithUnreadableStore_NeverDeletes(string? input)
        {
            var action = SecretSaveAction.Resolve(input, storeReadable: false);
            Assert.Equal(SecretSaveActionKind.KeepExisting, action.Kind);
            Assert.Null(action.Value);
        }
    }
}
