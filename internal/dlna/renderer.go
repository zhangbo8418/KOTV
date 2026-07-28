package dlna

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/koron/go-ssdp"
)

const dmrPort = 17890

// MediaState DMR 向控制端报告的播放态。
type MediaState struct {
	URI      string
	State    string // PLAYING / PAUSED_PLAYBACK / STOPPED / NO_MEDIA_PRESENT
	PosMs    int64
	DurMs    int64
}

// Renderer 最小 MediaRenderer：可被发现，接收投屏控制。
type Renderer struct {
	mu        sync.Mutex
	ad        *ssdp.Advertiser
	srv       *http.Server
	uuid      string
	onURI     func(uri string)
	onStop    func()
	onPause   func(pause bool)
	onSeek    func(ms int64)
	onNext    func()
	stateFn   func() MediaState
	location  string
	currentURI string
	transport  string // PLAYING / PAUSED_PLAYBACK / STOPPED
}

var (
	rendererMu sync.Mutex
	activeDMR  *Renderer
)

// RendererHooks DMR 回调。
type RendererHooks struct {
	OnURI   func(uri string)
	OnStop  func()
	OnPause func(pause bool)
	OnSeek  func(ms int64)
	OnNext  func()
	State   func() MediaState
}

// StartRenderer 启动被投端；已在跑则先停。
func StartRenderer(onURI func(string), onStop func(), onPause func(bool)) error {
	return StartRendererHooks(RendererHooks{OnURI: onURI, OnStop: onStop, OnPause: onPause})
}

// StartRendererHooks 带 Seek/状态的被投端。
func StartRendererHooks(h RendererHooks) error {
	rendererMu.Lock()
	defer rendererMu.Unlock()
	if activeDMR != nil {
		_ = activeDMR.Close()
		activeDMR = nil
	}
	r := &Renderer{
		uuid:      "uuid:kotv-dmr-" + shortID(),
		onURI:     h.OnURI,
		onStop:    h.OnStop,
		onPause:   h.OnPause,
		onSeek:    h.OnSeek,
		onNext:    h.OnNext,
		stateFn:   h.State,
		transport: "NO_MEDIA_PRESENT",
	}
	ip := LocalIP()
	if ip == "" {
		return fmt.Errorf("无可用局域网 IP")
	}
	r.location = fmt.Sprintf("http://%s:%d/dmr/desc.xml", ip, dmrPort)
	mux := http.NewServeMux()
	mux.HandleFunc("/dmr/desc.xml", r.handleDesc)
	mux.HandleFunc("/dmr/AVTransport/scpd.xml", r.handleAVSCPD)
	mux.HandleFunc("/dmr/ConnectionManager/scpd.xml", r.handleCMSCPD)
	mux.HandleFunc("/dmr/RenderingControl/scpd.xml", r.handleRCSCPD)
	mux.HandleFunc("/dmr/AVTransport/control", r.handleAVControl)
	mux.HandleFunc("/dmr/ConnectionManager/control", r.handleOKSOAP)
	mux.HandleFunc("/dmr/RenderingControl/control", r.handleOKSOAP)
	r.srv = &http.Server{Addr: fmt.Sprintf(":%d", dmrPort), Handler: mux}
	go func() {
		if err := r.srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Printf("DLNA DMR http: %v", err)
		}
	}()
	ad, err := ssdp.Advertise(
		"urn:schemas-upnp-org:device:MediaRenderer:1",
		r.uuid,
		r.location,
		"KO影视",
		1800,
	)
	if err != nil {
		_ = r.srv.Close()
		return err
	}
	r.ad = ad
	activeDMR = r
	log.Printf("DLNA DMR 已启动: %s", r.location)
	return nil
}

// StopRenderer 停止被投端。
func StopRenderer() {
	rendererMu.Lock()
	defer rendererMu.Unlock()
	if activeDMR != nil {
		_ = activeDMR.Close()
		activeDMR = nil
	}
}

func (r *Renderer) Close() error {
	if r.ad != nil {
		_ = r.ad.Close()
		r.ad = nil
	}
	if r.srv != nil {
		_ = r.srv.Close()
		r.srv = nil
	}
	return nil
}

func (r *Renderer) setTransport(state string) {
	r.mu.Lock()
	r.transport = state
	r.mu.Unlock()
}

func (r *Renderer) getTransport() string {
	if r.stateFn != nil {
		st := r.stateFn()
		if st.State != "" {
			return st.State
		}
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.transport
}

func (r *Renderer) snapshot() MediaState {
	st := MediaState{}
	r.mu.Lock()
	st.URI = r.currentURI
	fallback := r.transport
	r.mu.Unlock()
	st.State = fallback
	if r.stateFn != nil {
		live := r.stateFn()
		if live.URI != "" {
			st.URI = live.URI
		}
		if live.State != "" {
			st.State = live.State
		}
		st.PosMs = live.PosMs
		st.DurMs = live.DurMs
	}
	return st
}

func (r *Renderer) handleDesc(w http.ResponseWriter, _ *http.Request) {
	ip := LocalIP()
	body := fmt.Sprintf(`<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>KO影视</friendlyName>
    <manufacturer>KOTV</manufacturer>
    <modelName>KOTV</modelName>
    <UDN>%s</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <SCPDURL>/dmr/AVTransport/scpd.xml</SCPDURL>
        <controlURL>/dmr/AVTransport/control</controlURL>
        <eventSubURL>/dmr/AVTransport/event</eventSubURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
        <SCPDURL>/dmr/ConnectionManager/scpd.xml</SCPDURL>
        <controlURL>/dmr/ConnectionManager/control</controlURL>
        <eventSubURL>/dmr/ConnectionManager/event</eventSubURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
        <SCPDURL>/dmr/RenderingControl/scpd.xml</SCPDURL>
        <controlURL>/dmr/RenderingControl/control</controlURL>
        <eventSubURL>/dmr/RenderingControl/event</eventSubURL>
      </service>
    </serviceList>
  </device>
  <URLBase>http://%s:%d/</URLBase>
</root>`, r.uuid, ip, dmrPort)
	w.Header().Set("Content-Type", "text/xml; charset=utf-8")
	_, _ = w.Write([]byte(body))
}

func (r *Renderer) handleAVSCPD(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/xml; charset=utf-8")
	_, _ = w.Write([]byte(avTransportSCPD))
}

func (r *Renderer) handleCMSCPD(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/xml; charset=utf-8")
	_, _ = w.Write([]byte(minimalSCPD("ConnectionManager")))
}

func (r *Renderer) handleRCSCPD(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/xml; charset=utf-8")
	_, _ = w.Write([]byte(minimalSCPD("RenderingControl")))
}

func (r *Renderer) handleOKSOAP(w http.ResponseWriter, req *http.Request) {
	_, _ = io.Copy(io.Discard, req.Body)
	soapOK(w, "OK")
}

var (
	uriRe      = regexp.MustCompile(`(?is)<CurrentURI[^>]*>([^<]*)</CurrentURI>`)
	seekTarget = regexp.MustCompile(`(?is)<Target[^>]*>([^<]*)</Target>`)
	seekUnit   = regexp.MustCompile(`(?is)<Unit[^>]*>([^<]*)</Unit>`)
)

func (r *Renderer) handleAVControl(w http.ResponseWriter, req *http.Request) {
	body, _ := io.ReadAll(io.LimitReader(req.Body, 1<<20))
	soap := string(body)
	action := req.Header.Get("SOAPACTION")
	if action == "" {
		action = req.Header.Get("Soapaction")
	}
	action = strings.ToLower(action)
	switch {
	case strings.Contains(action, "setavtransporturi"):
		m := uriRe.FindStringSubmatch(soap)
		uri := ""
		if len(m) > 1 {
			uri = xmlUnescape(strings.TrimSpace(m[1]))
		}
		r.mu.Lock()
		r.currentURI = uri
		r.transport = "STOPPED"
		r.mu.Unlock()
		if uri != "" && r.onURI != nil {
			go r.onURI(uri)
		}
		soapOK(w, "SetAVTransportURIResponse")
	case strings.Contains(action, "play"):
		r.setTransport("PLAYING")
		if r.onPause != nil {
			go r.onPause(false)
		}
		soapOK(w, "PlayResponse")
	case strings.Contains(action, "pause"):
		r.setTransport("PAUSED_PLAYBACK")
		if r.onPause != nil {
			go r.onPause(true)
		}
		soapOK(w, "PauseResponse")
	case strings.Contains(action, "stop"):
		r.setTransport("STOPPED")
		if r.onStop != nil {
			go r.onStop()
		}
		soapOK(w, "StopResponse")
	case strings.Contains(action, "seek"):
		ms := parseSeekTargetMs(soap)
		if ms >= 0 && r.onSeek != nil {
			go r.onSeek(ms)
		}
		soapOK(w, "SeekResponse")
	case strings.Contains(action, "next"):
		if r.onNext != nil {
			go r.onNext()
		}
		soapOK(w, "NextResponse")
	case strings.Contains(action, "getpositioninfo"):
		r.writePositionInfo(w)
	case strings.Contains(action, "getmediainfo"):
		r.writeMediaInfo(w)
	case strings.Contains(action, "gettransportinfo"):
		state := r.getTransport()
		w.Header().Set("Content-Type", `text/xml; charset="utf-8"`)
		_, _ = fmt.Fprintf(w, `<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:GetTransportInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<CurrentTransportState>%s</CurrentTransportState>
<CurrentTransportStatus>OK</CurrentTransportStatus>
<CurrentSpeed>1</CurrentSpeed>
</u:GetTransportInfoResponse></s:Body></s:Envelope>`, xmlEscape(state))
	default:
		soapOK(w, "OK")
	}
}

func parseSeekTargetMs(soap string) int64 {
	tm := seekTarget.FindStringSubmatch(soap)
	if len(tm) < 2 {
		return -1
	}
	target := strings.TrimSpace(xmlUnescape(tm[1]))
	unit := "REL_TIME"
	if um := seekUnit.FindStringSubmatch(soap); len(um) > 1 {
		unit = strings.ToUpper(strings.TrimSpace(xmlUnescape(um[1])))
	}
	switch unit {
	case "REL_TIME", "ABS_TIME":
		return parseRelTimeMs(target)
	default:
		return parseRelTimeMs(target)
	}
}

func (r *Renderer) writePositionInfo(w http.ResponseWriter) {
	st := r.snapshot()
	w.Header().Set("Content-Type", `text/xml; charset="utf-8"`)
	_, _ = fmt.Fprintf(w, `<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<Track>1</Track>
<TrackDuration>%s</TrackDuration>
<TrackMetaData></TrackMetaData>
<TrackURI>%s</TrackURI>
<RelTime>%s</RelTime>
<AbsTime>%s</AbsTime>
<RelCount>2147483647</RelCount>
<AbsCount>2147483647</AbsCount>
</u:GetPositionInfoResponse></s:Body></s:Envelope>`,
		FormatRelTime(st.DurMs), xmlEscape(st.URI), FormatRelTime(st.PosMs), FormatRelTime(st.PosMs))
}

func (r *Renderer) writeMediaInfo(w http.ResponseWriter) {
	st := r.snapshot()
	w.Header().Set("Content-Type", `text/xml; charset="utf-8"`)
	_, _ = fmt.Fprintf(w, `<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:GetMediaInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<NrTracks>1</NrTracks>
<MediaDuration>%s</MediaDuration>
<CurrentURI>%s</CurrentURI>
<CurrentURIMetaData></CurrentURIMetaData>
<NextURI></NextURI>
<NextURIMetaData></NextURIMetaData>
<PlayMedium>NETWORK</PlayMedium>
<RecordMedium>NOT_IMPLEMENTED</RecordMedium>
<WriteStatus>NOT_IMPLEMENTED</WriteStatus>
</u:GetMediaInfoResponse></s:Body></s:Envelope>`,
		FormatRelTime(st.DurMs), xmlEscape(st.URI))
}

func soapOK(w http.ResponseWriter, name string) {
	w.Header().Set("Content-Type", `text/xml; charset="utf-8"`)
	_, _ = fmt.Fprintf(w, `<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:%s xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"/></s:Body></s:Envelope>`, name)
}

func xmlUnescape(s string) string {
	s = strings.ReplaceAll(s, "&amp;", "&")
	s = strings.ReplaceAll(s, "&lt;", "<")
	s = strings.ReplaceAll(s, "&gt;", ">")
	s = strings.ReplaceAll(s, "&quot;", `"`)
	s = strings.ReplaceAll(s, "&apos;", "'")
	return s
}

func xmlEscape(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	s = strings.ReplaceAll(s, `"`, "&quot;")
	return s
}

func shortID() string {
	return fmt.Sprintf("%d", time.Now().UnixNano()%1e12)
}

const avTransportSCPD = `<?xml version="1.0"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <actionList>
    <action><name>SetAVTransportURI</name></action>
    <action><name>Play</name></action>
    <action><name>Pause</name></action>
    <action><name>Stop</name></action>
    <action><name>Seek</name></action>
    <action><name>Next</name></action>
    <action><name>GetTransportInfo</name></action>
    <action><name>GetPositionInfo</name></action>
    <action><name>GetMediaInfo</name></action>
  </actionList>
  <serviceStateTable></serviceStateTable>
</scpd>`

func minimalSCPD(name string) string {
	_ = name
	return `<?xml version="1.0"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <actionList></actionList>
  <serviceStateTable></serviceStateTable>
</scpd>`
}
