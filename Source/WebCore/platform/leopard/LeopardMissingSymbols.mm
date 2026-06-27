// [leopard] Definitions for symbols whose implementing source files were
// removed from the 10.6 build (they soft-link 10.7+ frameworks). Each is
// referenced by compiled WebCore code, so without these dyld traps at first
// use (e.g. CertificateInfo on the HTTPS path, DictionaryLookup on hit-test,
// MediaSessionManagerCocoa now-playing, ResourceUsageThread). No-op / empty
// returns are correct here: media, now-playing, and resource-usage telemetry
// are all disabled on this build, and cert summary display is non-essential.
#include "config.h"

#include "CertificateInfo.h"
#include "DictionaryLookup.h"
#include "HitTestResult.h"
#include "MediaSessionManagerCocoa.h"
#include "NotImplemented.h"
#include "Range.h"
#include "ResourceUsageThread.h"

namespace WebCore {

CertificateInfo::Type CertificateInfo::type() const
{
    return Type::None;
}

Optional<CertificateInfo::SummaryInfo> CertificateInfo::summaryInfo() const
{
    return WTF::nullopt;
}

std::tuple<RefPtr<Range>, NSDictionary *> DictionaryLookup::rangeAtHitTestResult(const HitTestResult&)
{
    return { nullptr, nil };
}

void MediaSessionManagerCocoa::clearNowPlayingInfo()
{
}

void MediaSessionManagerCocoa::setNowPlayingInfo(bool, const NowPlayingInfo&)
{
}

#if ENABLE(RESOURCE_USAGE)
void ResourceUsageThread::platformSaveStateBeforeStarting()
{
}

void ResourceUsageThread::platformCollectCPUData(JSC::VM*, ResourceUsageData&)
{
}

void ResourceUsageThread::platformCollectMemoryData(JSC::VM*, ResourceUsageData&)
{
}
#endif // ENABLE(RESOURCE_USAGE)

} // namespace WebCore

namespace WTF {
namespace Persistence {

void Coder<WebCore::CertificateInfo>::encode(Encoder&, const WebCore::CertificateInfo&)
{
}

WTF::Optional<WebCore::CertificateInfo> Coder<WebCore::CertificateInfo>::decode(Decoder&)
{
    return WebCore::CertificateInfo { };
}

} // namespace Persistence
} // namespace WTF
