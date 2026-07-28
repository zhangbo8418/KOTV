package util

import "strings"

// UriResolve 对齐 TV catvod UriUtil.resolve（ExoPlayer 同源算法）。
func UriResolve(baseUri, referenceUri string) string {
	if baseUri == "" {
		baseUri = ""
	}
	if referenceUri == "" {
		referenceUri = ""
	}
	refIndices := getURIIndices(referenceUri)
	if refIndices[schemeColon] != -1 {
		uri := []byte(referenceUri)
		return removeDotSegments(uri, refIndices[pathIdx], refIndices[queryIdx])
	}
	baseIndices := getURIIndices(baseUri)
	if refIndices[fragmentIdx] == 0 {
		return baseUri[:baseIndices[fragmentIdx]] + referenceUri
	}
	if refIndices[queryIdx] == 0 {
		return baseUri[:baseIndices[queryIdx]] + referenceUri
	}
	if refIndices[pathIdx] != 0 {
		baseLimit := baseIndices[schemeColon] + 1
		uri := append([]byte(baseUri[:baseLimit]), referenceUri...)
		return removeDotSegments(uri, baseLimit+refIndices[pathIdx], baseLimit+refIndices[queryIdx])
	}
	if len(referenceUri) > refIndices[pathIdx] && referenceUri[refIndices[pathIdx]] == '/' {
		uri := append([]byte(baseUri[:baseIndices[pathIdx]]), referenceUri...)
		return removeDotSegments(uri, baseIndices[pathIdx], baseIndices[pathIdx]+refIndices[queryIdx])
	}
	if baseIndices[schemeColon]+2 < baseIndices[pathIdx] && baseIndices[pathIdx] == baseIndices[queryIdx] {
		uri := append(append([]byte(baseUri[:baseIndices[pathIdx]]), '/'), referenceUri...)
		return removeDotSegments(uri, baseIndices[pathIdx], baseIndices[pathIdx]+refIndices[queryIdx]+1)
	}
	lastSlashIndex := strings.LastIndex(baseUri[:baseIndices[queryIdx]], "/")
	baseLimit := baseIndices[pathIdx]
	if lastSlashIndex != -1 {
		baseLimit = lastSlashIndex + 1
	}
	uri := append([]byte(baseUri[:baseLimit]), referenceUri...)
	return removeDotSegments(uri, baseIndices[pathIdx], baseLimit+refIndices[queryIdx])
}

const (
	schemeColon = 0
	pathIdx     = 1
	queryIdx    = 2
	fragmentIdx = 3
)

func getURIIndices(uriString string) [4]int {
	var indices [4]int
	if uriString == "" {
		indices[schemeColon] = -1
		return indices
	}
	length := len(uriString)
	fragmentIndex := strings.IndexByte(uriString, '#')
	if fragmentIndex == -1 {
		fragmentIndex = length
	}
	queryIndex := strings.IndexByte(uriString, '?')
	if queryIndex == -1 || queryIndex > fragmentIndex {
		queryIndex = fragmentIndex
	}
	schemeIndexLimit := strings.IndexByte(uriString, '/')
	if schemeIndexLimit == -1 || schemeIndexLimit > queryIndex {
		schemeIndexLimit = queryIndex
	}
	schemeIndex := strings.IndexByte(uriString, ':')
	if schemeIndex > schemeIndexLimit {
		schemeIndex = -1
	}
	hasAuthority := schemeIndex+2 < queryIndex && len(uriString) > schemeIndex+2 &&
		uriString[schemeIndex+1] == '/' && uriString[schemeIndex+2] == '/'
	var pathIndex int
	if hasAuthority {
		pathIndex = strings.IndexByte(uriString[schemeIndex+3:], '/')
		if pathIndex != -1 {
			pathIndex += schemeIndex + 3
		}
		if pathIndex == -1 || pathIndex > queryIndex {
			pathIndex = queryIndex
		}
	} else {
		pathIndex = schemeIndex + 1
	}
	indices[schemeColon] = schemeIndex
	indices[pathIdx] = pathIndex
	indices[queryIdx] = queryIndex
	indices[fragmentIdx] = fragmentIndex
	return indices
}

func removeDotSegments(uri []byte, offset, limit int) string {
	if offset >= limit {
		return string(uri)
	}
	if uri[offset] == '/' {
		offset++
	}
	segmentStart := offset
	i := offset
	for i <= limit {
		var nextSegmentStart int
		if i == limit {
			nextSegmentStart = i
		} else if uri[i] == '/' {
			nextSegmentStart = i + 1
		} else {
			i++
			continue
		}
		if i == segmentStart+1 && uri[segmentStart] == '.' {
			uri = append(uri[:segmentStart], uri[nextSegmentStart:]...)
			limit -= nextSegmentStart - segmentStart
			i = segmentStart
		} else if i == segmentStart+2 && uri[segmentStart] == '.' && uri[segmentStart+1] == '.' {
			// 对齐 Java：从 segmentStart-2 往前找上一段，避免命中「..」前的那个 /
			searchEnd := segmentStart - 1
			if searchEnd < 0 {
				searchEnd = 0
			}
			prevSegmentStart := lastIndexByte(uri[:searchEnd], '/') + 1
			removeFrom := prevSegmentStart
			if removeFrom < offset {
				removeFrom = offset
			}
			uri = append(uri[:removeFrom], uri[nextSegmentStart:]...)
			limit -= nextSegmentStart - removeFrom
			segmentStart = prevSegmentStart
			i = prevSegmentStart
		} else {
			i++
			segmentStart = i
		}
	}
	return string(uri)
}

func lastIndexByte(b []byte, c byte) int {
	for i := len(b) - 1; i >= 0; i-- {
		if b[i] == c {
			return i
		}
	}
	return -1
}
