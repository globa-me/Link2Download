using System.Globalization;
using System.Windows.Data;

namespace Link2Download.Windows.App.Converters;

public sealed class SpeedConverter : IValueConverter
{
    private readonly ByteSizeConverter _byteSizeConverter = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is null)
        {
            return "Speed unknown";
        }

        return $"{_byteSizeConverter.Convert(value, targetType, parameter, culture)}/s";
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        throw new NotSupportedException();
    }
}
