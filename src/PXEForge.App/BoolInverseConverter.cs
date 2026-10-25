using System.Globalization;
using System.Windows.Data;

namespace PXEForge.App;

[ValueConversion(typeof(bool), typeof(bool))]
public sealed class BoolInverseConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is bool b && !b;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is bool b && !b;
}
