package com.bobo.kotv.extractor;

import android.net.Uri;
import android.util.Base64;

import androidx.media3.common.MimeTypes;

import org.schabi.newpipe.extractor.NewPipe;
import org.schabi.newpipe.extractor.localization.Localization;
import org.schabi.newpipe.extractor.stream.AudioStream;
import org.schabi.newpipe.extractor.stream.Stream;
import org.schabi.newpipe.extractor.stream.StreamInfo;
import org.schabi.newpipe.extractor.stream.StreamType;
import org.schabi.newpipe.extractor.stream.VideoStream;
import org.w3c.dom.Document;
import org.w3c.dom.Element;

import java.io.StringWriter;
import java.nio.charset.StandardCharsets;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.stream.Collectors;

import javax.xml.parsers.DocumentBuilderFactory;
import javax.xml.transform.OutputKeys;
import javax.xml.transform.Transformer;
import javax.xml.transform.TransformerFactory;
import javax.xml.transform.dom.DOMSource;
import javax.xml.transform.stream.StreamResult;

/**
 * YouTube / youtu.be → 可播 URL（直播 HLS/DASH，点播自建 MPD 或渐进流）。
 */
public final class YouTubeExtractor {

  private static final String DASH_NAMESPACE = "urn:mpeg:dash:schema:mpd:2011";
  private static final String XSI_NAMESPACE = "http://www.w3.org/2001/XMLSchema-instance";
  private static final String DASH_PROFILE = "urn:mpeg:dash:profile:isoff-on-demand:2011";

  private static volatile boolean inited;

  private YouTubeExtractor() {}

  public static boolean match(String url) {
    try {
      String host = Uri.parse(url.trim()).getHost();
      if (host == null) return false;
      host = host.toLowerCase(Locale.US);
      return host.contains("youtube.com") || host.contains("youtu.be");
    } catch (Throwable t) {
      return false;
    }
  }

  public static String fetch(String url) throws Exception {
    ensureInit();
    return getPlayUrl(StreamInfo.getInfo(url));
  }

  private static synchronized void ensureInit() {
    if (inited) return;
    NewPipe.init(NewPipeImpl.get(), Localization.fromLocale(Locale.getDefault()));
    inited = true;
  }

  private static String getPlayUrl(StreamInfo info) throws Exception {
    return isLive(info) ? getLive(info) : getMpd(info);
  }

  private static boolean isLive(StreamInfo info) {
    return StreamType.LIVE_STREAM.equals(info.getStreamType());
  }

  private static String getLive(StreamInfo info) {
    if (info.getHlsUrl() != null && !info.getHlsUrl().isEmpty()) return info.getHlsUrl();
    if (info.getDashMpdUrl() != null && !info.getDashMpdUrl().isEmpty()) return info.getDashMpdUrl();
    return "";
  }

  private static String getMpd(StreamInfo info) throws Exception {
    List<AudioStream> audioFormats = getSegmentStreams(info.getAudioStreams());
    List<VideoStream> videoFormats = getSegmentStreams(info.getVideoOnlyStreams());
    if (audioFormats.isEmpty() && videoFormats.isEmpty()) {
      return getProgressive(info.getVideoStreams());
    }
    return toDataUri(MimeTypes.APPLICATION_MPD, documentToXml(createMpd(info, videoFormats, audioFormats)));
  }

  private static String getProgressive(List<VideoStream> formats) {
    return formats.stream()
        .filter(format -> format.getContent() != null && !format.getContent().isEmpty())
        .max(Comparator.comparingInt(VideoStream::getHeight).thenComparingInt(VideoStream::getBitrate))
        .map(VideoStream::getContent)
        .orElse("");
  }

  private static Document createMpd(StreamInfo info, List<VideoStream> videoFormats, List<AudioStream> audioFormats)
      throws Exception {
    String duration = "PT" + Math.max(0, info.getDuration()) + "S";
    Document doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().newDocument();
    Element mpd = append(doc, doc, "MPD");
    attr(mpd, "xmlns:xsi", XSI_NAMESPACE);
    attr(mpd, "xmlns", DASH_NAMESPACE);
    attr(mpd, "xsi:schemaLocation", DASH_NAMESPACE + " DASH-MPD.xsd");
    attr(mpd, "type", "static");
    attr(mpd, "mediaPresentationDuration", duration);
    attr(mpd, "minBufferTime", "PT1.500S");
    attr(mpd, "profiles", DASH_PROFILE);
    Element period = append(doc, mpd, "Period");
    attr(period, "duration", duration);
    attr(period, "start", "PT0S");
    for (VideoStream format : videoFormats) addVideo(doc, period, format);
    for (AudioStream format : audioFormats) addAudio(doc, period, format);
    return doc;
  }

  private static void addVideo(Document doc, Element period, VideoStream format) {
    Element representation =
        addRepresentation(
            doc,
            period,
            "video",
            format.getFormat().getMimeType(),
            format.getItag(),
            format.getBitrate(),
            format.getCodec(),
            format.getContent());
    attr(representation, "height", format.getHeight());
    attr(representation, "width", format.getWidth());
    attr(representation, "frameRate", format.getFps());
    attr(representation, "maxPlayoutRate", "1");
    attr(representation, "startWithSAP", "1");
    addSegmentBase(
        doc,
        representation,
        format.getIndexStart(),
        format.getIndexEnd(),
        format.getInitStart(),
        format.getInitEnd());
  }

  private static void addAudio(Document doc, Element period, AudioStream format) {
    Element representation =
        addRepresentation(
            doc,
            period,
            "audio",
            format.getFormat().getMimeType(),
            format.getItag(),
            format.getBitrate(),
            format.getCodec(),
            format.getContent());
    if (format.getItagItem() != null) {
      attr(representation, "audioSamplingRate", format.getItagItem().getSampleRate());
    }
    addSegmentBase(
        doc,
        representation,
        format.getIndexStart(),
        format.getIndexEnd(),
        format.getInitStart(),
        format.getInitEnd());
  }

  private static Element addRepresentation(
      Document doc,
      Element period,
      String contentType,
      String mimeType,
      int id,
      int bandwidth,
      String codecs,
      String url) {
    Element adaptationSet = append(doc, period, "AdaptationSet");
    attr(adaptationSet, "contentType", contentType);
    attr(adaptationSet, "mimeType", mimeType);
    attr(adaptationSet, "subsegmentAlignment", "true");
    Element content = append(doc, adaptationSet, "ContentComponent");
    attr(content, "contentType", contentType);
    Element representation = append(doc, adaptationSet, "Representation");
    attr(representation, "id", id);
    attr(representation, "bandwidth", bandwidth);
    attr(representation, "codecs", codecs);
    attr(representation, "mimeType", mimeType);
    append(doc, representation, "BaseURL").setTextContent(url);
    return representation;
  }

  private static void addSegmentBase(
      Document doc, Element representation, long indexStart, long indexEnd, long initStart, long initEnd) {
    Element segmentBase = append(doc, representation, "SegmentBase");
    attr(segmentBase, "indexRange", range(indexStart, indexEnd));
    Element initialization = append(doc, segmentBase, "Initialization");
    attr(initialization, "range", range(initStart, initEnd));
  }

  private static <T extends Stream> List<T> getSegmentStreams(List<T> formats) {
    return formats.stream().filter(YouTubeExtractor::hasSegmentRanges).collect(Collectors.toList());
  }

  private static boolean hasSegmentRanges(Stream format) {
    if (format instanceof VideoStream video) {
      return hasRange(video.getIndexStart(), video.getIndexEnd())
          && hasRange(video.getInitStart(), video.getInitEnd());
    }
    if (format instanceof AudioStream audio) {
      return hasRange(audio.getIndexStart(), audio.getIndexEnd())
          && hasRange(audio.getInitStart(), audio.getInitEnd());
    }
    return false;
  }

  private static boolean hasRange(long start, long end) {
    return start >= 0 && end >= start;
  }

  private static String range(long start, long end) {
    return start + "-" + end;
  }

  private static String toDataUri(String mimeType, String content) {
    return "data:" + mimeType + ";base64," + Base64.encodeToString(content.getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP);
  }

  private static String documentToXml(Document doc) throws Exception {
    Transformer transformer = TransformerFactory.newInstance().newTransformer();
    transformer.setOutputProperty(OutputKeys.VERSION, "1.0");
    transformer.setOutputProperty(OutputKeys.ENCODING, StandardCharsets.UTF_8.name());
    transformer.setOutputProperty(OutputKeys.STANDALONE, "no");
    StringWriter result = new StringWriter();
    transformer.transform(new DOMSource(doc), new StreamResult(result));
    return result.toString();
  }

  private static Element append(Document doc, org.w3c.dom.Node parent, String name) {
    Element child = doc.createElement(name);
    parent.appendChild(child);
    return child;
  }

  private static void attr(Element element, String name, String value) {
    if (value != null && !value.isEmpty()) element.setAttribute(name, value);
  }

  private static void attr(Element element, String name, int value) {
    if (value > 0) attr(element, name, String.valueOf(value));
  }

  private static void attr(Element element, String name, long value) {
    if (value > 0) attr(element, name, String.valueOf(value));
  }
}
