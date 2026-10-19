def check():
    try:
        if "__compiled__" in globals():
            return True
    except:
        pass
    return False
