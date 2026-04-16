using System.Globalization;
using System.Windows.Data;

namespace Link2Download.Windows.App.Converters;

public sealed class DurationConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is null)
        {
            return "Unknown duration";
        }

        var seconds = System.Convert.ToDouble(value, CultureInfo.InvariantCulture);
        var duration = TimeSpan.FromSeconds(seconds);
        return duration.TotalHours >= 1
            ? duration.ToString(@"hh\:mm\:ss", CultureInfo.InvariantCulture)
            : duration.ToString(@"mm\:ss", CultureInfo.InvariantCulture);
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        throw new NotSupportedException();
    }
}
