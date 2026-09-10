using System;
using System.Collections.Generic;
using TokenBar.Models;
using TokenBar.Services;
using Xunit;

namespace TokenBar.Tests
{
    public class ProviderOrderingTests
    {
        [Fact]
        public void NullOrder_UsesDefaultOrder()
        {
            Assert.Equal(0, ProviderOrdering.GetSortIndex("openai", null));
            Assert.Equal(8, ProviderOrdering.GetSortIndex("aliyun", null));
            Assert.Equal(ProviderOrdering.DefaultOrder.Length, ProviderOrdering.GetSortIndex("custom:x", null));
        }

        [Fact]
        public void ListedKeys_KeepUserOrder()
        {
            var order = new List<string> { "glm", "openai" };
            Assert.Equal(0, ProviderOrdering.GetSortIndex("glm", order));
            Assert.Equal(1, ProviderOrdering.GetSortIndex("openai", order));
        }

        [Fact]
        public void UnlistedKeys_GoAfterListed_InDefaultOrder()
        {
            var order = new List<string> { "glm", "openai" };
            var claude = ProviderOrdering.GetSortIndex("claude", order);
            var aliyun = ProviderOrdering.GetSortIndex("aliyun", order);
            var custom = ProviderOrdering.GetSortIndex("custom:" + Guid.NewGuid(), order);
            Assert.True(claude >= order.Count);
            Assert.True(claude < aliyun);
            Assert.True(aliyun < custom);
        }

        [Fact]
        public void KeyOf_RoundTripsThroughParseProviderType()
        {
            foreach (ProviderType type in Enum.GetValues(typeof(ProviderType)))
            {
                var key = ProviderOrdering.KeyOf(type);
                Assert.Contains(key, ProviderOrdering.DefaultOrder);
                Assert.Equal(type, ProviderOrdering.ParseProviderType(key));
            }
        }

        [Fact]
        public void CustomKey_RoundTrips()
        {
            var id = Guid.NewGuid();
            var key = ProviderOrdering.CustomKey(id);
            Assert.True(ProviderOrdering.TryParseCustomKey(key, out var parsed));
            Assert.Equal(id, parsed);
            Assert.False(ProviderOrdering.TryParseCustomKey("openai", out _));
            Assert.Null(ProviderOrdering.ParseProviderType(key));
        }
    }
}
