import Foundation

/// Largest-Triangle-Three-Buckets downsampling (Steinarsson, 2013): keeps the visual shape of a
/// series with far fewer points. Used to keep long cooks smooth in Swift Charts.
public enum LTTB {
    public static func downsample(_ samples: [Sample], to threshold: Int) -> [Sample] {
        guard threshold >= 3, samples.count > threshold else { return samples }

        let x = { (s: Sample) in s.time.timeIntervalSinceReferenceDate }
        var result: [Sample] = [samples[0]]
        result.reserveCapacity(threshold)

        let bucketSize = Double(samples.count - 2) / Double(threshold - 2)
        var a = 0

        for i in 0..<(threshold - 2) {
            // Average of the next bucket is the third triangle vertex.
            let nextStart = Int(Double(i + 1) * bucketSize) + 1
            let nextEnd = min(Int(Double(i + 2) * bucketSize) + 1, samples.count)
            var avgX = 0.0, avgY = 0.0
            for j in nextStart..<nextEnd {
                avgX += x(samples[j])
                avgY += samples[j].celsius
            }
            let count = Double(max(nextEnd - nextStart, 1))
            avgX /= count
            avgY /= count

            let start = Int(Double(i) * bucketSize) + 1
            let end = Int(Double(i + 1) * bucketSize) + 1
            let ax = x(samples[a]), ay = samples[a].celsius
            var maxArea = -1.0
            var chosen = start
            for j in start..<end {
                let area = abs((ax - avgX) * (samples[j].celsius - ay) - (ax - x(samples[j])) * (avgY - ay))
                if area > maxArea {
                    maxArea = area
                    chosen = j
                }
            }
            result.append(samples[chosen])
            a = chosen
        }
        result.append(samples[samples.count - 1])
        return result
    }
}
