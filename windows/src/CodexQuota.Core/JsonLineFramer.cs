namespace CodexQuota.Core;

public sealed class JsonLineFramer(int maximumFrameBytes = 1_048_576)
{
    private readonly int _maximumFrameBytes = maximumFrameBytes > 0
        ? maximumFrameBytes
        : throw new ArgumentOutOfRangeException(nameof(maximumFrameBytes));
    private readonly List<byte> _buffer = [];

    public IReadOnlyList<byte[]> Append(ReadOnlySpan<byte> bytes)
    {
        var frames = new List<byte[]>();
        foreach (var value in bytes)
        {
            if (value == (byte)'\n')
            {
                var count = _buffer.Count;
                if (count > 0 && _buffer[count - 1] == (byte)'\r')
                {
                    count--;
                }

                if (count > 0)
                {
                    frames.Add(_buffer.GetRange(0, count).ToArray());
                }

                _buffer.Clear();
                continue;
            }

            if (_buffer.Count >= _maximumFrameBytes)
            {
                _buffer.Clear();
                throw new InvalidDataException("JSONL frame exceeds the configured limit.");
            }

            _buffer.Add(value);
        }

        return frames;
    }

    public void Reset() => _buffer.Clear();
}
